defmodule GroupStay.Reservations do
  @moduledoc "Processes ordered partner operations and keeps reservation deposit accounting."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, Repo}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @max_cents 9_223_372_036_854_775_807
  @public_fields ~w(group_id guest_id property_id revision booked_on arrival_on departure_on rate_plan status rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a

  def submit(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents: coalesce(sum(g.deposit_paid_cents), 0),
          cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0)
        }
    )
  end

  defp process(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    # SQLite has one writer. Queue local writes before taking a connection so
    # contending transactions cannot exhaust the pool or block its native workers.
    # IMMEDIATE also protects revisions and balances from other service processes.
    # Each operation commits independently, including within a partner batch.
    lock = {{__MODULE__, Repo.get_dynamic_repo()}, self()}

    result =
      :global.trans(
        lock,
        fn ->
          Repo.transaction(fn -> apply_operation(operation) end, mode: :immediate)
        end,
        [node()]
      )

    case result do
      {:ok, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "applied"})
      {:error, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    unless identifier?(operation["operation_id"]) and identifier?(operation["group_id"]) and
             operation["type"] in @types do
      reject("invalid_operation")
    end

    if operation["type"] == "open_group" do
      open_group(operation, operation_date(operation))
    else
      group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
      check_revision(group, operation)
      if group.status != "active", do: reject("group_not_active")
      apply_to_group(group, operation, operation_date(operation))
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp open_group(operation, booked_on) do
    require_fields(operation, ~w(guest_id property_id arrival_on departure_on rate_plan rooms))

    unless identifier?(operation["guest_id"]) and identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    arrival = parse_date(operation["arrival_on"], "invalid_stay")
    departure = parse_date(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure, arrival)
    if nights < 1, do: reject("invalid_stay")

    plan = operation["rate_plan"]
    unless plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")
    rooms = validate_rooms(operation["rooms"])

    {lodging, deposit} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging, deposit} ->
        amount = nights * room["nightly_rate_cents"]
        room_deposit = if plan == "flexible", do: div(amount * 20 + 50, 100), else: amount
        {lodging + amount, deposit + room_deposit}
      end)

    if lodging > @max_cents, do: reject("invalid_rooms")

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: plan,
        rooms: rooms,
        lodging_total_cents: lodging,
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp apply_to_group(group, %{"type" => "record_cash_payment"} = operation, _date) do
    require_fields(operation, ~w(amount_cents))
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    group = update(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp apply_to_group(group, %{"type" => "reschedule_group"} = operation, date) do
    require_fields(operation, ~w(new_arrival_on))
    arrival = parse_date(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, date) == :gt, do: reject("invalid_stay")
    departure = shift_departure(arrival, Date.diff(group.departure_on, group.arrival_on))
    group = update(group, %{arrival_on: arrival, departure_on: departure})

    %{
      group_id: group.group_id,
      new_arrival_on: arrival,
      new_departure_on: departure,
      revision: group.revision
    }
  end

  defp apply_to_group(group, %{"type" => "cancel_group"}, date) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, date) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    group =
      update(group, %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained
      })

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: group.revision
    }
  end

  defp update(group, fields) do
    group
    |> Ecto.Changeset.change(Map.put(fields, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      Repo.rollback(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) and is_integer(rate) and rate >= 0 and rate <= @max_cents

        _ ->
          false
      end)

    unless valid, do: reject("invalid_rooms")
    ids = Enum.map(rooms, & &1["room_id"])
    if length(Enum.uniq(ids)) != length(ids), do: reject("invalid_rooms")
    Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))
  end

  defp validate_rooms(_), do: reject("invalid_rooms")
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp require_fields(operation, fields) do
    unless Enum.all?(fields, &Map.has_key?(operation, &1)), do: reject("invalid_operation")
  end

  defp operation_date(operation), do: parse_date(operation["occurred_on"], "invalid_operation")

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp parse_date(_, code), do: reject(code)

  defp shift_departure(arrival, nights) do
    departure = Date.add(arrival, nights)
    if departure.year > 9999, do: reject("invalid_stay")
    departure
  rescue
    ArgumentError -> reject("invalid_stay")
  end

  defp reject(code), do: Repo.rollback(%{code: code})
end
