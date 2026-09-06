defmodule GroupStay.Reservations do
  @moduledoc "Ordered partner operations and persistent deposit accounting."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, Repo}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @required %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => []
  }

  def batch(operations), do: Enum.map(operations, &process/1)

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.from_struct()
        |> Map.drop([:__meta__, :refunded_cents, :retained_cents])
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

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

  defp process(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # Acquiring the SQLite write lock before reading prevents two writers from
    # both accepting the same expected revision.
    case Repo.transaction(fn -> apply_operation(op) end, mode: :immediate) do
      {:ok, result} -> Map.merge(result, %{operation_id: id, status: "applied"})
      {:error, result} -> Map.merge(result, %{operation_id: id, status: "rejected"})
    end
  end

  defp apply_operation(op) when is_map(op) do
    type = op["type"]

    unless type in @types and identifier?(op["operation_id"]) and identifier?(op["group_id"]),
      do: reject("invalid_operation")

    if type == "open_group" do
      validate_required(op)
      open(op)
    else
      group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

      if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
        Repo.rollback(%{
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        })
      end

      validate_required(op)
      unless group.status == "active", do: reject("group_not_active")
      update(group, op)
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp validate_required(op) do
    unless Enum.all?(["occurred_on" | @required[op["type"]]], &Map.has_key?(op, &1)),
      do: reject("invalid_operation")

    if op["type"] == "open_group" and
         not (identifier?(op["guest_id"]) and identifier?(op["property_id"])),
       do: reject("invalid_operation")
  end

  defp open(op) do
    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    booked = date(op["occurred_on"], "invalid_stay")
    arrival = date(op["arrival_on"], "invalid_stay")
    departure = date(op["departure_on"], "invalid_stay")
    nights = Date.diff(departure, arrival)
    unless nights > 0, do: reject("invalid_stay")
    rooms = op["rooms"]

    unless is_list(rooms) and rooms != [] and Enum.all?(rooms, &valid_room?/1),
      do: reject("invalid_rooms")

    ids = Enum.map(rooms, & &1["room_id"])
    unless length(ids) == length(Enum.uniq(ids)), do: reject("invalid_rooms")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")

    lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

    due =
      Enum.sum(
        Enum.map(lodging, fn amount ->
          if op["rate_plan"] == "flexible", do: div(amount * 20 + 50, 100), else: amount
        end)
      )

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        rooms: Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))),
        lodging_total_cents: Enum.sum(lodging),
        deposit_due_cents: due
      })

    %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}
  end

  defp update(group, %{"type" => "record_cash_payment"} = op) do
    date(op["occurred_on"], "invalid_operation")
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    updated = save(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp update(group, %{"type" => "reschedule_group"} = op) do
    occurred = date(op["occurred_on"], "invalid_stay")
    arrival = date(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred) == :gt, do: reject("invalid_stay")
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
    unless departure.year in 0..9999, do: reject("invalid_stay")
    updated = save(group, %{arrival_on: arrival, departure_on: departure})

    %{
      group_id: group.group_id,
      new_arrival_on: arrival,
      new_departure_on: departure,
      revision: updated.revision
    }
  end

  defp update(group, %{"type" => "cancel_group"} = op) do
    occurred = date(op["occurred_on"], "invalid_operation")
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    updated =
      save(group, %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        refunded_cents: refunded,
        retained_cents: retained
      })

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: updated.revision
    }
  end

  defp save(group, attrs) do
    group
    |> Ecto.Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp valid_room?(room) when is_map(room) do
    identifier?(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] >= 0
  end

  defp valid_room?(_), do: false

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp date(_, code), do: reject(code)
  defp reject(code), do: Repo.rollback(%{code: code})
end
