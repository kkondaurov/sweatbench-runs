defmodule GroupStay.Deposits.FundingTransfer do
  @moduledoc """
  Moves held room funding between active groups without changing its accounting provenance.

  Source allocations are drawn newest-first across cash and hotel credit. The resulting pieces are
  filled into destination rooms in their original order and receive new allocation-order values,
  while retaining their payment identity or original credit lot.
  """

  import Ecto.Query
  alias Ecto.Changeset

  alias GroupStay.Deposits.{
    AllocationOrder,
    CashAllocation,
    CreditAllocation,
    PaymentDisposition,
    Room
  }

  alias GroupStay.Repo

  @doc "Moves `amount` of held funding and marks every participating durable cash payment."
  def move(source, destination, amount) do
    with {:ok, moved} <- draw_funding(source, amount),
         :ok <- allocate_funding(destination, moved, amount),
         :ok <- mark_cash_payments(moved),
         do: :ok
  end

  defp draw_funding(source, amount) do
    cash =
      Repo.all(from a in CashAllocation, where: a.group_id == ^source.id)
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit =
      Repo.all(from a in CreditAllocation, where: a.group_id == ^source.id)
      |> Enum.map(&%{kind: :credit, allocation: &1})

    (cash ++ credit)
    |> Enum.sort_by(& &1.allocation.allocation_order, :desc)
    |> Enum.reduce_while({:ok, [], amount}, &draw_piece/2)
    |> case do
      {:ok, moved} -> {:ok, moved}
      {:ok, _moved, _left} -> {:error, :transfer_exceeds_held_funding}
      error -> error
    end
  end

  defp draw_piece(funding, {:ok, moved, left}) do
    allocation = funding.allocation
    used = min(allocation.amount_cents, left)

    result =
      if used == allocation.amount_cents,
        do: Repo.delete(allocation),
        else:
          allocation
          |> Changeset.change(amount_cents: allocation.amount_cents - used)
          |> Repo.update()

    case result do
      {:ok, _} ->
        piece = Map.put(funding, :amount_cents, used)

        if left == used,
          do: {:halt, {:ok, Enum.reverse([piece | moved])}},
          else: {:cont, {:ok, [piece | moved], left - used}}

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp allocate_funding(destination, moved, amount) do
    destination
    |> room_uses(amount)
    |> intersect_allocations(moved)
    |> Enum.reduce_while(:ok, fn {room, funding, used}, :ok ->
      case insert_allocation(destination, room, funding, used) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp room_uses(group, amount) do
    {uses, _} =
      Repo.all(
        from r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          order_by: r.position,
          preload: [:cash_allocations, :credit_allocations]
      )
      |> Enum.reduce_while({[], amount}, fn room, {uses, left} ->
        paid =
          Enum.sum_by(room.cash_allocations, & &1.amount_cents) +
            Enum.sum_by(room.credit_allocations, & &1.amount_cents)

        used = min(max(room.deposit_due_cents - paid, 0), left)
        uses = if used > 0, do: [{room, used} | uses], else: uses
        if left == used, do: {:halt, {uses, 0}}, else: {:cont, {uses, left - used}}
      end)

    Enum.reverse(uses)
  end

  defp intersect_allocations(rooms, funding), do: intersect_allocations(rooms, funding, [])
  defp intersect_allocations([], _, acc), do: Enum.reverse(acc)
  defp intersect_allocations(_, [], acc), do: Enum.reverse(acc)

  defp intersect_allocations(
         [{room, room_amount} | rooms],
         [%{amount_cents: funding_amount} = funding | rest],
         acc
       ) do
    used = min(room_amount, funding_amount)
    rooms = if room_amount == used, do: rooms, else: [{room, room_amount - used} | rooms]

    funding_left =
      if funding_amount == used,
        do: rest,
        else: [%{funding | amount_cents: funding_amount - used} | rest]

    intersect_allocations(rooms, funding_left, [{room, funding, used} | acc])
  end

  defp insert_allocation(group, room, %{kind: :cash, allocation: source}, amount) do
    %CashAllocation{}
    |> Changeset.cast(
      %{
        group_id: group.id,
        room_id: room.id,
        payment_operation_id: source.payment_operation_id,
        amount_cents: amount,
        allocation_order: AllocationOrder.next()
      },
      [:group_id, :room_id, :payment_operation_id, :amount_cents, :allocation_order]
    )
    |> Repo.insert()
  end

  defp insert_allocation(group, room, %{kind: :credit, allocation: source}, amount) do
    %CreditAllocation{}
    |> Changeset.cast(
      %{
        group_id: group.id,
        room_id: room.id,
        credit_lot_id: source.credit_lot_id,
        operation_id: source.operation_id,
        amount_cents: amount,
        allocation_order: AllocationOrder.next()
      },
      [
        :group_id,
        :room_id,
        :credit_lot_id,
        :operation_id,
        :amount_cents,
        :allocation_order
      ]
    )
    |> Repo.insert()
  end

  defp mark_cash_payments(moved) do
    moved
    |> Enum.filter(&(&1.kind == :cash))
    |> Enum.map(& &1.allocation.payment_operation_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn payment_id, :ok ->
      payment = Repo.get_by!(PaymentDisposition, payment_operation_id: payment_id)

      case payment |> Changeset.change(participated_in_transfer: true) |> Repo.update() do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
