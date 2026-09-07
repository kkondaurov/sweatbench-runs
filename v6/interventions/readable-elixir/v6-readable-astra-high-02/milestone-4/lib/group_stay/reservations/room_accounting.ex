defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Allocates funding in original room order and settles selected room deposits.

  Group totals are cached sums of active rooms and their held allocations. Every
  mutation runs in the operation transaction; reads never repair or mutate balances.
  Cash history remains in allocation dispositions after rooms are cancelled.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CancellationPolicy, HotelCredit, Room, RoomAllocation}

  def rooms(group) do
    Repo.all(from room in Room, where: room.group_id == ^group.group_id, order_by: room.position)
    |> Repo.preload(:allocations)
    |> Enum.map(fn room ->
      held = Enum.filter(room.allocations, &(&1.disposition == "held"))
      cash = held |> Enum.filter(&is_nil(&1.credit_lot_id)) |> total()
      credit = held |> Enum.reject(&is_nil(&1.credit_lot_id)) |> total()
      %{room | cash_paid_cents: cash, credit_paid_cents: credit}
    end)
  end

  def allocate(group, amount, provenance) do
    0 =
      Enum.reduce(rooms(group), amount, fn room, needed ->
        available =
          if room.status == :active,
            do: room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents,
            else: 0

        used = min(needed, available)

        if used > 0 do
          %RoomAllocation{room_id: room.id, amount_cents: used}
          |> change(provenance)
          |> Repo.insert!()
        end

        needed - used
      end)

    :ok
  end

  def refresh(group) do
    active = Enum.filter(rooms(group), &(&1.status == :active))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    change(group,
      status: if(active == [], do: :cancelled, else: :active),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
      deposit_paid_cents: cash + credit,
      credit_paid_cents: credit
    )
  end

  def cancel(group, operation, date) do
    active = Enum.filter(rooms(group), &(&1.status == :active))

    ids =
      if operation["type"] == "cancel_group",
        do: Enum.map(active, & &1.room_id),
        else: operation["room_ids"]

    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, date)

    with :ok <- validate_rooms(active, ids),
         :ok <- validate_method(method, refundable?) do
      selected = Enum.filter(active, &(&1.room_id in ids))

      allocations =
        selected
        |> Enum.flat_map(& &1.allocations)
        |> Enum.filter(&(&1.disposition == "held"))
        |> Enum.sort_by(& &1.id)

      {cash, credit} = Enum.split_with(allocations, &is_nil(&1.credit_lot_id))
      cash_amount = total(cash)

      disposition =
        cond do
          method == "hotel_credit" -> "converted_to_credit"
          refundable? -> "refunded"
          true -> "retained"
        end

      issued =
        if disposition == "converted_to_credit",
          do: HotelCredit.issue(group, operation["operation_id"], date, cash),
          else: 0

      Enum.each(cash, &move(&1, &1.amount_cents, disposition))
      HotelCredit.settle_allocations(group, credit, date, refundable?)
      Enum.each(selected, &(&1 |> change(status: :cancelled) |> Repo.update!()))

      refunded = if disposition == "refunded", do: cash_amount, else: 0
      retained = if disposition == "retained", do: cash_amount, else: 0
      converted = if disposition == "converted_to_credit", do: cash_amount, else: 0

      changeset =
        group
        |> refresh()
        |> change(
          cash_refunded_cents: group.cash_refunded_cents + refunded,
          cash_retained_cents: group.cash_retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        )

      result = %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}

      result =
        if operation["type"] == "cancel_rooms",
          do: Map.put(result, :cancelled_room_ids, Enum.map(selected, & &1.room_id)),
          else: result

      {:ok, changeset, result}
    end
  end

  @doc "Moves all or part of a cash slice to a new disposition."
  def move(allocation, amount, disposition) do
    if amount == allocation.amount_cents do
      allocation |> change(disposition: disposition) |> Repo.update!()
    else
      allocation |> change(amount_cents: allocation.amount_cents - amount) |> Repo.update!()

      Repo.insert!(%RoomAllocation{
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: amount,
        disposition: disposition
      })
    end
  end

  def total(allocations), do: Enum.sum(Enum.map(allocations, & &1.amount_cents))

  defp validate_rooms(active, ids) when is_list(ids) and ids != [] do
    active_ids = Enum.map(active, & &1.room_id)

    if length(Enum.uniq(ids)) == length(ids) and Enum.all?(ids, &(&1 in active_ids)),
      do: :ok,
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_, _), do: {:error, "invalid_rooms"}

  defp validate_method(method, _) when method not in ["cash", "hotel_credit"],
    do: {:error, "invalid_operation"}

  defp validate_method("hotel_credit", false), do: {:error, "refund_method_not_available"}
  defp validate_method(_, _), do: :ok
end
