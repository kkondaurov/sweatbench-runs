defmodule GroupStay.Groups do
  @moduledoc """
  Group reservations, room-level funding allocations, and the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit
  alias GroupStay.Groups.Backfill
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.RoomAllocation
  alias GroupStay.Operations.Record

  @policy_cutoff ~D[2027-01-01]
  @flex_windows %{"flex-14" => 14, "flex-30" => 30}
  @reversed_dispositions ~w(reduced charged_back transferred)

  @doc """
  Returns the group with its rooms in their original order, or nil. Reading a
  group brings any pre-room-accounting funding forward first, so the room
  view always agrees with the group's totals.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      %Group{} ->
        {:ok, group} =
          Repo.transaction(fn ->
            Backfill.backfill_all()

            Group
            |> Repo.get(group_id)
            |> Repo.preload(rooms: from(r in GroupStay.Groups.Room, order_by: [asc: r.position]))
          end)

        group
    end
  end

  def get_group(_), do: nil

  @doc """
  The deposit still owed on a group. Unpaid deposit stops being due once the
  group is cancelled.
  """
  def outstanding_deposit_cents(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit_cents(%Group{}), do: 0

  @doc """
  The cash portion of the deposit paid on a group.
  """
  def cash_paid_cents(%Group{} = group) do
    group.deposit_paid_cents - group.credit_paid_cents
  end

  @doc """
  The cancellation policy fixed when the group was opened. Flexible groups
  booked before the policy cutoff keep the 14-day window; later flexible
  groups use the 30-day window. Advance purchase is never refundable.
  """
  def policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The last date on which cancelling the group is refundable, or nil for
  advance purchase.
  """
  def refundable_until(%Group{} = group) do
    refundable_until(group.arrival_on, policy_version(group))
  end

  def refundable_until(arrival_on, policy_version)

  def refundable_until(_arrival_on, "advance-nonrefundable"), do: nil

  def refundable_until(arrival_on, policy_version) do
    Date.add(arrival_on, -Map.fetch!(@flex_windows, policy_version))
  end

  @doc """
  Whether a cancellation occurring on `occurred_on` is refundable.
  """
  def refundable?(%Group{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end

  ## room allocations

  @doc """
  Allocates one funding operation's cash or credit to the group's active
  rooms in their original order, filling one room's deposit before moving to
  the next. `chunks` are `{lot_id, amount}` portions in consumption order;
  cash funding passes a nil lot.
  """
  def allocate_funding(group_id, chunks, operation_id, disposition \\ "held") do
    rooms =
      GroupStay.Groups.Room
      |> where([r], r.group_id == ^group_id and r.status == "active")
      |> order_by([r], asc: r.position)
      |> Repo.all()

    paid = held_paid_by_room(group_id)

    chunks = Enum.map(chunks, fn {lot_id, amount} -> {operation_id, lot_id, amount} end)
    fill_allocations(group_id, rooms, paid, chunks, disposition)
  end

  @doc """
  The fill at the heart of room accounting. Places `chunks` —
  `{operation_id, lot_id, amount}` entries in funding order — into `rooms` in
  order, filling one room's deposit before moving to the next. `paid` tracks
  the cents already allocated to each room so the fill continues where
  earlier funding stopped. The kind follows the lot: credit carries a lot,
  cash does not. `transferred` marks rows created by a deposit transfer.
  """
  def fill_allocations(group_id, rooms, paid, chunks, disposition, transferred \\ false)

  def fill_allocations(_group_id, _rooms, _paid, [], _disposition, _transferred), do: :ok

  def fill_allocations(
        group_id,
        rooms,
        paid,
        [{_op_id, _lot_id, 0} | rest],
        disposition,
        transferred
      ),
      do: fill_allocations(group_id, rooms, paid, rest, disposition, transferred)

  def fill_allocations(
        group_id,
        rooms,
        paid,
        [{op_id, lot_id, amount} | rest],
        disposition,
        transferred
      ) do
    {paid, remaining} =
      place(group_id, rooms, paid, op_id, lot_id, amount, disposition, transferred)

    if remaining > 0, do: raise("funding exceeds the group's room deposits")
    fill_allocations(group_id, rooms, paid, rest, disposition, transferred)
  end

  defp place(_group_id, _rooms, paid, _op_id, _lot_id, 0, _disposition, _transferred),
    do: {paid, 0}

  defp place(_group_id, [], paid, _op_id, _lot_id, amount, _disposition, _transferred),
    do: {paid, amount}

  defp place(group_id, [room | rooms], paid, op_id, lot_id, amount, disposition, transferred) do
    room_paid = Map.get(paid, room.id, 0)
    capacity = room.deposit_due_cents - room_paid
    take = min(capacity, amount)

    if take > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%RoomAllocation{
        group_id: group_id,
        room_id: room.id,
        operation_id: op_id,
        lot_id: lot_id,
        kind: if(lot_id, do: "credit", else: "cash"),
        amount_cents: take,
        disposition: disposition,
        transferred: transferred,
        inserted_at: now,
        updated_at: now
      })
    end

    place(
      group_id,
      rooms,
      Map.put(paid, room.id, room_paid + take),
      op_id,
      lot_id,
      amount - take,
      disposition,
      transferred
    )
  end

  @doc """
  Held cents already allocated to each room of the group, keyed by room id.
  """
  def held_paid_by_room(group_id) do
    RoomAllocation
    |> where([a], a.group_id == ^group_id and a.disposition == "held")
    |> group_by([a], a.room_id)
    |> select([a], {a.room_id, sum(a.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The cash and credit paid toward each room, keyed by room id. Funding that
  was reduced, charged back, or transferred away no longer counts as paid;
  settled funding (refunded, retained, converted, restored, or consumed)
  remains the room's paid history.
  """
  def paid_by_room(group_id) do
    RoomAllocation
    |> where([a], a.group_id == ^group_id and a.disposition not in ^@reversed_dispositions)
    |> group_by([a], [a.room_id, a.kind])
    |> select([a], {a.room_id, a.kind, sum(a.amount_cents)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {room_id, kind, amount}, acc ->
      entry = Map.get(acc, room_id, %{cash: 0, credit: 0})
      Map.put(acc, room_id, Map.put(entry, String.to_existing_atom(kind), amount))
    end)
  end

  ## payment statements

  @doc """
  The current disposition of one durably recorded, applied cash payment.
  Reading a statement never changes state beyond bringing legacy funding
  forward.
  """
  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    Backfill.backfill_all()

    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{} = record ->
        result = Jason.decode!(record.result)

        if record.type == "record_cash_payment" and result["status"] == "applied" do
          {:ok, build_statement(payment_operation_id, result)}
        else
          {:error, "payment_not_reconcilable"}
        end
    end
  end

  def payment_statement(_), do: {:error, "operation_not_found"}

  defp build_statement(payment_operation_id, result) do
    sums = disposition_sums(payment_operation_id)

    statement = %{
      payment_operation_id: payment_operation_id,
      original_group_id: result["group_id"],
      recorded_cents: result["amount_cents"],
      held_cents: Map.get(sums, "held", 0),
      refunded_cents: Map.get(sums, "refunded", 0),
      retained_cents: Map.get(sums, "retained", 0),
      converted_to_credit_cents: Map.get(sums, "converted", 0),
      reduced_cents: Map.get(sums, "reduced", 0),
      charged_back_cents: Map.get(sums, "charged_back", 0)
    }

    # Once any funding from the payment has participated in a transfer, the
    # statement reports where its held cash currently sits, by group. Payments
    # that have never participated keep the earlier statement shape.
    if participated_in_transfer?(payment_operation_id) do
      Map.put(statement, :held_by_group, held_by_group(payment_operation_id))
    else
      statement
    end
  end

  defp participated_in_transfer?(payment_operation_id) do
    RoomAllocation
    |> where([a], a.operation_id == ^payment_operation_id and a.transferred == true)
    |> select([a], count(a.id))
    |> Repo.one() > 0
  end

  defp held_by_group(payment_operation_id) do
    RoomAllocation
    |> where(
      [a],
      a.operation_id == ^payment_operation_id and a.kind == "cash" and a.disposition == "held"
    )
    |> group_by([a], a.group_id)
    |> order_by([a], asc: a.group_id)
    |> select([a], %{group_id: a.group_id, amount_cents: sum(a.amount_cents)})
    |> Repo.all()
  end

  @doc """
  The current disposition totals of one payment's cash, keyed by disposition.
  """
  def disposition_sums(payment_operation_id) do
    RoomAllocation
    |> where([a], a.operation_id == ^payment_operation_id and a.kind == "cash")
    |> group_by([a], a.disposition)
    |> select([a], {a.disposition, sum(a.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  ## ledger

  @doc """
  Finance totals across all groups. `as_of` sets the date used to report
  credit expiry.
  """
  def ledger(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: cash_disposition("held"),
      cash_refunded_cents: cash_disposition("refunded"),
      cash_retained_cents: cash_disposition("retained"),
      cash_converted_to_credit_cents: cash_disposition("converted"),
      cash_reduced_cents: cash_disposition("reduced"),
      cash_charged_back_cents: cash_disposition("charged_back"),
      credit_liability_cents: Credit.liability_cents(as_of),
      credit_shortfall_cents: Credit.shortfall_cents()
    }
  end

  defp cash_disposition(disposition) do
    RoomAllocation
    |> where([a], a.kind == "cash" and a.disposition == ^disposition)
    |> select([a], sum(a.amount_cents))
    |> Repo.one() || 0
  end
end
