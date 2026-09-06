defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations and maintains group deposits and cancellation settlements.

  Each operation has its own transaction. SQLite's immediate transaction mode acquires
  the write lock before reading a revision or balance, including across server processes.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, HotelCredit, Room}

  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group)
  @max_cents 9_223_372_036_854_775_807

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> group_data()
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.guest_credit(guest_id, on)

  def report_date(nil), do: {:ok, Date.utc_today()}

  def report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = parsed} when year >= 0 and year <= 9999 -> {:ok, parsed}
      _ -> {:error, :invalid_date}
    end
  end

  def report_date(_value), do: {:error, :invalid_date}

  def ledger(on \\ Date.utc_today()) do
    # Sum exact integers in a read snapshot, without SQLite SUM's 64-bit overflow
    # or loading every reservation into memory.
    {:ok, totals} =
      Repo.transaction(fn ->
        query =
          from g in Group,
            select: %{
              cash_held_cents: g.deposit_paid_cents - g.credit_paid_cents,
              cash_refunded_cents: g.cash_refunded_cents,
              cash_retained_cents: g.cash_retained_cents,
              cash_converted_to_credit_cents: g.cash_converted_to_credit_cents,
              credit_liability_cents: g.credit_paid_cents
            }

        totals =
          query
          |> Repo.stream()
          |> Enum.reduce(
            %{
              cash_held_cents: 0,
              cash_refunded_cents: 0,
              cash_retained_cents: 0,
              cash_converted_to_credit_cents: 0,
              credit_liability_cents: 0
            },
            fn row, totals ->
              Map.merge(totals, row, fn _key, total, amount -> total + amount end)
            end
          )

        available =
          on
          |> HotelCredit.available_query()
          |> select([lot], lot.remaining_cents)
          |> Repo.stream()
          |> Enum.reduce(0, &+/2)

        Map.update!(totals, :credit_liability_cents, &(&1 + available))
      end)

    totals
  end

  defp apply_operation(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    # SQLite has one writer. Queue local writers in Elixir so waiting native
    # connections cannot occupy every dirty IO scheduler and starve the writer.
    # The database lock still serializes writes from other OS processes/nodes.
    outcome =
      :global.trans(
        {{__MODULE__, :write}, self()},
        fn -> Repo.transaction(fn -> dispatch(operation) end, mode: :immediate) end,
        [node()]
      )

    case outcome do
      {:ok, result} ->
        Map.merge(result, %{operation_id: operation_id, status: "applied"})

      {:error, rejection} ->
        Map.merge(rejection, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp dispatch(operation) when is_map(operation) do
    unless operation["type"] in @operation_types and identifier?(operation["operation_id"]) and
             identifier?(operation["group_id"]) do
      reject("invalid_operation")
    end

    if operation["type"] == "open_group" do
      open_group(operation)
    else
      group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
      check_revision(group, operation)
      occurred_on = operation_date(operation)

      required_fields(operation, required_fields_for(operation["type"]))
      if group.status != "active", do: reject("group_not_active")

      {changes, result} = update_group(group, operation, occurred_on)

      group
      |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
      |> Repo.update!()

      Map.merge(result, %{group_id: group.group_id, revision: group.revision + 1})
    end
  end

  defp dispatch(_operation), do: reject("invalid_operation")

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      reject("stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp open_group(operation) do
    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    booked_on = operation_date(operation)
    required_fields(operation, ~w(guest_id property_id arrival_on departure_on rate_plan rooms))

    unless identifier?(operation["guest_id"]) and identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    arrival_on = date(operation["arrival_on"], "invalid_stay")
    departure_on = date(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    if nights < 1, do: reject("invalid_stay")

    rate_plan = operation["rate_plan"]
    unless rate_plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")

    rooms = validate_rooms(operation["rooms"])
    lodging_total = Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights)))
    if lodging_total > @max_cents, do: reject("invalid_rooms")

    deposit_due =
      Enum.sum(
        Enum.map(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights
          if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        end)
      )

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      })

    Repo.insert_all(
      Room,
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group.group_id,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          position: position
        }
      end)
    )

    %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: 1}
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = operation, _occurred_on) do
    {amount, outstanding} = payment_amount(group, operation)

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: outstanding - amount}}
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    {amount, outstanding} = payment_amount(group, operation)
    HotelCredit.apply_to_group(group, amount, occurred_on)

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       credit_paid_cents: group.credit_paid_cents + amount
     }, %{amount_cents: amount, outstanding_deposit_cents: outstanding - amount}}
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    arrival_on = date(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival_on, occurred_on) == :gt, do: reject("invalid_stay")

    departure_on = Date.add(arrival_on, Date.diff(group.departure_on, group.arrival_on))

    # Keep shifted dates representable in the API's four-digit ISO calendar format.
    if departure_on.year > 9999, do: reject("invalid_stay")

    {%{arrival_on: arrival_on, departure_on: departure_on},
     %{
       new_arrival_on: arrival_on,
       new_departure_on: departure_on,
       policy_version: group.policy_version,
       refundable_until: refundable_until(%{group | arrival_on: arrival_on})
     }}
  end

  defp update_group(group, %{"type" => "cancel_group"} = operation, occurred_on) do
    method = Map.get(operation, "refund_method", "cash")
    unless method in ~w(cash hotel_credit), do: reject("invalid_operation")

    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt

    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    cash = group.deposit_paid_cents - group.credit_paid_cents
    refunded = if refundable and method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if method == "hotel_credit", do: cash, else: 0

    issued = HotelCredit.issue(group, operation["operation_id"], converted, occurred_on)
    HotelCredit.settle(group, refundable, occurred_on)

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       deposit_paid_cents: 0,
       credit_paid_cents: 0,
       cash_refunded_cents: refunded,
       cash_retained_cents: retained,
       cash_converted_to_credit_cents: converted
     }, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
  end

  defp payment_amount(group, operation) do
    amount = operation["amount_cents"]
    unless cents?(amount) and amount > 0, do: reject("invalid_amount")

    outstanding = group.deposit_due_cents - group.deposit_paid_cents
    if amount > outstanding, do: reject("payment_exceeds_outstanding")
    {amount, outstanding}
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    days = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          identifier?(room_id) and cents?(rate)

        _ ->
          false
      end)

    unless valid?, do: reject("invalid_rooms")

    room_ids = Enum.map(rooms, & &1["room_id"])
    if length(Enum.uniq(room_ids)) != length(room_ids), do: reject("invalid_rooms")
    rooms
  end

  defp validate_rooms(_rooms), do: reject("invalid_rooms")

  defp required_fields_for("record_cash_payment"), do: ["amount_cents"]
  defp required_fields_for("apply_hotel_credit"), do: ["amount_cents"]
  defp required_fields_for("reschedule_group"), do: ["new_arrival_on"]
  defp required_fields_for("cancel_group"), do: []

  defp required_fields(operation, fields) do
    unless Enum.all?(fields, &Map.has_key?(operation, &1)), do: reject("invalid_operation")
  end

  defp operation_date(operation), do: date(operation["occurred_on"], "invalid_operation")

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = parsed} when year >= 0 and year <= 9999 -> parsed
      _ -> reject(code)
    end
  end

  defp date(_value, code), do: reject(code)

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp cents?(value), do: is_integer(value) and value >= 0 and value <= @max_cents

  defp reject(code, details \\ %{}), do: Repo.rollback(Map.put(details, :code, code))

  defp group_data(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :revision,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents
    ])
    |> Map.put(:cash_paid_cents, group.deposit_paid_cents - group.credit_paid_cents)
    |> Map.put(:refundable_until, refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, group.deposit_due_cents - group.deposit_paid_cents)
    |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
  end
end
