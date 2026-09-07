defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations and exposes reservation and cash balances.

  Each operation holds SQLite's write reservation from lookup through commit.
  This makes revision comparisons atomic, including across service processes.
  Handled rejections roll back domain effects and retain their durable result.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Operations}
  alias GroupStay.Reservations.{Group, CancellationPolicy, HotelCredit}

  @required %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "apply_hotel_credit" => ~w(amount_cents)
  }

  def get_group(id) do
    case Repo.get(Group, id) do
      nil -> nil
      group -> Group.to_map(group)
    end
  end

  def guest_credit(id, on \\ Date.utc_today()), do: HotelCredit.balance(id, on)

  def ledger(on \\ Date.utc_today()) do
    # All totals must describe the same snapshot while deposits are being settled.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents - g.credit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0),
          cash_converted_to_credit_cents: coalesce(sum(g.converted_cents), 0)
        }
    )
    |> Map.put(:credit_liability_cents, HotelCredit.liability(on))
  end

  def submit(operations), do: Enum.map(operations, &apply_operation/1)

  defp apply_operation(operation) do
    Operations.execute(operation, fn ->
      validate_envelope!(operation)
      dispatch(operation)
    end)
  end

  defp validate_envelope!(op) when is_map(op) do
    required = Map.get(@required, op["type"])

    unless required && Enum.all?(~w(operation_id group_id), &identifier?(op[&1])) &&
             Map.has_key?(op, "occurred_on") do
      reject("invalid_operation")
    end
  end

  defp validate_envelope!(_), do: reject("invalid_operation")

  defp validate_fields!(op) do
    unless Enum.all?(Map.fetch!(@required, op["type"]), &Map.has_key?(op, &1)) do
      reject("invalid_operation")
    end
  end

  defp dispatch(%{"type" => "open_group"} = op) do
    validate_fields!(op)
    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")

    unless identifier?(op["guest_id"]) && identifier?(op["property_id"]),
      do: reject("invalid_operation")

    booked_on = date!(op["occurred_on"], "invalid_stay")
    arrival_on = date!(op["arrival_on"], "invalid_stay")
    departure_on = date!(op["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    if nights < 1, do: reject("invalid_stay")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")
    rooms = rooms!(op["rooms"])
    lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

    deposit =
      if op["rate_plan"] == "flexible",
        do: Enum.sum(Enum.map(lodging, &div(&1 * 20 + 50, 100))),
        else: Enum.sum(lodging)

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: op["rate_plan"],
        policy_version: CancellationPolicy.version(op["rate_plan"], booked_on),
        rooms: rooms,
        lodging_total_cents: Enum.sum(lodging),
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp dispatch(op) do
    group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

    if Map.has_key?(op, "expected_revision") && op["expected_revision"] !== group.revision do
      Operations.reject(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: op["expected_revision"],
        actual_revision: group.revision
      })
    end

    validate_fields!(op)
    if group.status != "active", do: reject("group_not_active")
    occurred_on = date!(op["occurred_on"], "invalid_stay")
    {changes, result} = change(group, op, occurred_on)
    revision = group.revision + 1
    group |> Ecto.Changeset.change(Map.put(changes, :revision, revision)) |> Repo.update!()
    Map.merge(result, %{group_id: group.group_id, revision: revision})
  end

  defp change(group, %{"type" => "record_cash_payment", "amount_cents" => amount}, _) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > Group.outstanding(group), do: reject("payment_exceeds_outstanding")

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "apply_hotel_credit", "amount_cents" => amount}, on) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > Group.outstanding(group), do: reject("payment_exceeds_outstanding")
    HotelCredit.apply(group, amount, on)

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       credit_paid_cents: group.credit_paid_cents + amount
     }, %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    arrival = date!(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred_on) == :gt, do: reject("invalid_stay")
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp change(group, %{"type" => "cancel_group"} = op, occurred_on) do
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    refundable = CancellationPolicy.refundable?(group, occurred_on)
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    cash = group.deposit_paid_cents - group.credit_paid_cents
    converted = if method == "hotel_credit", do: cash, else: 0
    refunded = if refundable and method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    issued =
      if converted > 0,
        do: HotelCredit.issue(group, op["operation_id"], occurred_on, converted),
        else: 0

    HotelCredit.settle(group, refundable, occurred_on)

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       refunded_cents: refunded,
       retained_cents: retained,
       converted_cents: converted
     }, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
  end

  defp rooms!(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) && is_integer(rate) && rate >= 0

        _ ->
          false
      end)

    unless valid, do: reject("invalid_rooms")
    ids = Enum.map(rooms, & &1["room_id"])
    unless length(Enum.uniq(ids)) == length(ids), do: reject("invalid_rooms")
    Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))
  end

  defp rooms!(_), do: reject("invalid_rooms")

  defp date!(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp date!(_, code), do: reject(code)
  defp identifier?(value), do: is_binary(value) && byte_size(value) > 0
  defp reject(code), do: Operations.reject(%{code: code})
end
