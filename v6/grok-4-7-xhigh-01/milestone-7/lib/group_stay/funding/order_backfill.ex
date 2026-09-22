defmodule GroupStay.Funding.OrderBackfill do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Funding
  alias GroupStay.Funding.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  def run do
    if Funding.order_ready?() and missing_order?() do
      ops = funding_operations()
      start = if present_order?(), do: current_max() + 1, else: 1

      Repo.all(from g in Group, order_by: [asc: g.inserted_at, asc: g.id])
      |> Enum.reduce(start, fn group, next ->
        stamp_rows(ordered_rows(group, ops), next)
      end)

      stamp_remaining()
    end

    :ok
  end

  defp missing_order? do
    Repo.exists?(from a in CashAllocation, where: is_nil(a.order_lo)) or
      Repo.exists?(from a in Allocation, where: is_nil(a.order_lo))
  end

  defp present_order? do
    Repo.exists?(from a in CashAllocation, where: not is_nil(a.order_lo)) or
      Repo.exists?(from a in Allocation, where: not is_nil(a.order_lo))
  end

  defp current_max do
    cash =
      Repo.one(
        from a in CashAllocation,
          where: not is_nil(a.order_lo),
          select: max(fragment("? + ? - 1", a.order_lo, a.amount_cents))
      ) || 0

    credit =
      Repo.one(
        from a in Allocation,
          where: not is_nil(a.order_lo),
          select: max(fragment("? + ? - 1", a.order_lo, a.amount_cents))
      ) || 0

    max(cash, credit)
  end

  defp stamp_remaining do
    next = if present_order?(), do: current_max() + 1, else: 1

    cash =
      Repo.all(
        from a in CashAllocation,
          where: is_nil(a.order_lo),
          order_by: [asc: a.inserted_at, asc: a.sequence, asc: a.id]
      )

    credit =
      Repo.all(
        from a in Allocation,
          where: is_nil(a.order_lo),
          order_by: [asc: a.inserted_at, asc: a.id]
      )

    stamp_rows(cash ++ credit, next)
  end

  defp ordered_rows(group, ops) do
    case reconstruct(group, ops) do
      {:ok, rows} -> rows
      :error -> fallback_order(group)
    end
  end

  defp reconstruct(group, ops) do
    cash = cash_rows(group)
    credit = credit_rows(group)
    group_ops = Enum.filter(ops, &(&1.group_id == group.group_id))

    with {:ok, slices} <- slice_credit(credit, group_ops),
         :ok <- known_cash?(cash, group_ops) do
      {:ok, interleave(cash, slices, group_ops)}
    else
      _ -> :error
    end
  end

  defp slice_credit(rows, ops) do
    credit_ops = Enum.filter(ops, &(&1.type == "apply_hotel_credit"))
    durable = Enum.sum(Enum.map(credit_ops, & &1.amount))
    total = Enum.sum(Enum.map(rows, & &1.amount_cents))
    legacy = total - durable

    if legacy < 0 do
      :error
    else
      amounts = [legacy | Enum.map(credit_ops, & &1.amount)]

      case consume_amounts(rows, amounts) do
        {:ok, slices, []} -> {:ok, slices}
        _ -> :error
      end
    end
  end

  defp consume_amounts(rows, amounts) do
    Enum.reduce_while(amounts, {:ok, [], rows}, fn amount, {:ok, slices, rows} ->
      case take_exact(rows, amount) do
        {:ok, taken, rest} -> {:cont, {:ok, slices ++ [taken], rest}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, slices, rest} -> {:ok, slices, rest}
      :error -> :error
    end
  end

  defp take_exact(rows, 0), do: {:ok, [], rows}

  defp take_exact(rows, need), do: do_take(rows, need, [])

  defp do_take(rows, 0, acc), do: {:ok, Enum.reverse(acc), rows}

  defp do_take([row | rest], need, acc) when row.amount_cents <= need do
    do_take(rest, need - row.amount_cents, [row | acc])
  end

  defp do_take(_rows, _need, _acc), do: :error

  defp known_cash?(cash, ops) do
    known = MapSet.new(Enum.map(ops, & &1.operation_id))

    if Enum.all?(cash, fn row ->
         is_nil(row.operation_id) or MapSet.member?(known, row.operation_id)
       end) do
      :ok
    else
      :error
    end
  end

  defp interleave(cash, [legacy_credit | credit_slices], ops) do
    legacy_cash = Enum.filter(cash, &is_nil(&1.operation_id))
    by_op = Enum.group_by(cash, & &1.operation_id)

    {rows, _slices} =
      Enum.reduce(ops, {legacy_cash ++ legacy_credit, credit_slices}, fn op, {rows, slices} ->
        case op.type do
          "record_cash_payment" ->
            {rows ++ Map.get(by_op, op.operation_id, []), slices}

          "apply_hotel_credit" ->
            [slice | rest] = slices
            {rows ++ slice, rest}
        end
      end)

    rows
  end

  defp fallback_order(group) do
    cash = Enum.map(cash_rows(group), &{:cash, &1})
    credit = Enum.map(credit_rows(group), &{:credit, &1})

    (cash ++ credit)
    |> Enum.sort_by(fn
      {:cash, row} -> {row.inserted_at, 0, row.sequence || 0, row.id}
      {:credit, row} -> {row.inserted_at, 1, 0, row.id}
    end)
    |> Enum.map(fn {_kind, row} -> row end)
  end

  defp stamp_rows(rows, next) do
    Enum.reduce(rows, next, fn row, next ->
      if is_nil(row.order_lo) do
        row
        |> Ecto.Changeset.change(%{order_lo: next})
        |> Repo.update!()

        next + row.amount_cents
      else
        next
      end
    end)
  end

  defp cash_rows(group) do
    Repo.all(
      from a in CashAllocation,
        where: a.group_id == ^group.id,
        order_by: [asc: a.sequence, asc: a.id]
    )
  end

  defp credit_rows(group) do
    Repo.all(
      from a in Allocation,
        where: a.group_id == ^group.id,
        order_by: [asc: fragment("rowid")]
    )
  end

  defp funding_operations do
    Record
    |> where([r], r.type in ["record_cash_payment", "apply_hotel_credit"])
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.flat_map(&decode_funding/1)
  end

  defp decode_funding(record) do
    case Jason.decode(record.result) do
      {:ok, %{"status" => "applied", "group_id" => group_id, "amount_cents" => amount}}
      when is_binary(group_id) and is_integer(amount) and amount > 0 ->
        [
          %{
            operation_id: record.operation_id,
            type: record.type,
            group_id: group_id,
            amount: amount
          }
        ]

      _ ->
        []
    end
  end
end
