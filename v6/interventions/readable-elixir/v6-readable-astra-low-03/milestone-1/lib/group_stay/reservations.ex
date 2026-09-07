defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order, with one atomic transaction per operation.
  SQLite immediate transactions acquire the write reservation before reading,
  keeping revision comparisons and settlement updates atomic across callers.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @required %{
    "open_group" => ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(group_id amount_cents),
    "reschedule_group" => ~w(group_id new_arrival_on),
    "cancel_group" => ~w(group_id)
  }

  def submit(operations), do: Enum.map(operations, &apply_operation/1)
  def get_group(id), do: Repo.get(Group, id)

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0)
        }
    )
  end

  defp apply_operation(operation) do
    id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    case Repo.transaction(fn -> dispatch(operation) end, mode: :immediate) do
      {:ok, result} -> Map.merge(result, %{operation_id: id, status: "applied"})
      {:error, error} -> Map.merge(error, %{operation_id: id, status: "rejected"})
    end
  end

  defp dispatch(op) when is_map(op) do
    required = @required[op["type"]]

    unless required && Enum.all?(required, &Map.has_key?(op, &1)) &&
             identifier?(op["operation_id"]) && identifier?(op["group_id"]),
           do: reject("invalid_operation")

    occurred_on = date(op["occurred_on"])
    unless occurred_on, do: reject("invalid_operation")

    if op["type"] == "open_group" do
      open_group(op, occurred_on)
    else
      group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

      if Map.has_key?(op, "expected_revision") && op["expected_revision"] !== group.revision do
        Repo.rollback(%{
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        })
      end

      unless group.status == "active", do: reject("group_not_active")
      {changes, result} = change_group(group, op, occurred_on)

      updated =
        group
        |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
        |> Repo.update!()

      Map.merge(result, %{group_id: updated.group_id, revision: updated.revision})
    end
  end

  defp dispatch(_), do: reject("invalid_operation")

  defp open_group(op, booked_on) do
    unless identifier?(op["guest_id"]) && identifier?(op["property_id"]),
      do: reject("invalid_operation")

    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    arrival = date(op["arrival_on"])
    departure = date(op["departure_on"])

    unless arrival && departure && Date.compare(departure, arrival) == :gt,
      do: reject("invalid_stay")

    rooms = op["rooms"]
    unless valid_rooms?(rooms), do: reject("invalid_rooms")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")

    nights = Date.diff(departure, arrival)
    amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
    deposit = Enum.sum(Enum.map(amounts, &deposit(&1, op["rate_plan"])))

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        rooms: Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))),
        lodging_total_cents: Enum.sum(amounts),
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp change_group(group, %{"type" => "record_cash_payment"} = op, _) do
    amount = op["amount_cents"]
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > Group.outstanding(group), do: reject("payment_exceeds_outstanding")

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
  end

  defp change_group(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    arrival = date(op["new_arrival_on"])
    unless arrival && Date.compare(arrival, occurred_on) == :gt, do: reject("invalid_stay")
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{new_arrival_on: arrival, new_departure_on: departure}}
  end

  defp change_group(group, %{"type" => "cancel_group"}, occurred_on) do
    refundable = group.rate_plan == "flexible" && Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       deposit_paid_cents: 0,
       refunded_cents: refunded,
       retained_cents: retained
     }, %{refunded_cents: refunded, retained_cents: retained}}
  end

  # Integer arithmetic avoids floating-point drift, rounding each room separately.
  defp deposit(amount, "flexible"), do: div(amount * 20 + 50, 100)
  defp deposit(amount, "advance_purchase"), do: amount

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => id, "nightly_rate_cents" => rate} ->
        identifier?(id) && is_integer(rate) && rate >= 0

      _ ->
        false
    end) && length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
  defp identifier?(value), do: is_binary(value) && byte_size(value) > 0

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp reject(code), do: Repo.rollback(%{code: code})
end
