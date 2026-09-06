defmodule GroupStay.Reservations.AllocationOrder do
  @moduledoc """
  Gives allocations written before deposit transfers existed their place in the shared order.

  Cash and hotel credit fund the same room deposits, and a transfer draws from them in one order:
  the reverse of the order the allocations were created in. Cash allocations and credit
  applications live in separate tables, so that order is carried by an `allocation_seq` the two
  share, which rows written by earlier releases do not have.

  Those rows are put back in order the way room accounting laid them out in the first place: each
  group's unattributed senior block first, its aggregate cash before its hotel credit, and the
  funding durable records account for afterwards in the order those records were committed. A
  credit application never named the operation that created it, so the applications are matched to
  the credit operations they came from by amount, working back from the most recently recorded one.
  Where room accounting had to split one application over two rooms, the part it moved to the
  second room is the one place that match can put an application on the wrong side of a boundary;
  it is credit either way, and no record of the original interleaving survives to do better.

  This runs once, from the migration that introduces deposit transfers. It reads and writes through
  table names rather than schemas, so that a database upgrading from any earlier release sees only
  the columns that existed when it was written.
  """

  import Ecto.Query

  alias GroupStay.Partner.Journal
  alias GroupStay.Repo

  @funding_types ~w(record_cash_payment apply_hotel_credit)

  # Funding that no durable record accounts for came from before those records existed, and is
  # senior to everything a record does account for.
  @unattributed -1

  @doc """
  Numbers every existing allocation, across every group, in the order it was funded.
  """
  def backfill do
    records = funding_records()

    Repo.all(from g in "groups", order_by: [asc: g.id], select: {g.id, g.group_id})
    |> Enum.reduce(0, fn {id, group_id}, seq ->
      number(entries(id, Map.get(records, group_id, [])), seq)
    end)

    :ok
  end

  defp number(entries, seq) do
    entries
    |> Enum.sort_by(fn entry -> {entry.rank, entry.kind, entry.id} end)
    |> Enum.reduce(seq, fn entry, seq ->
      Repo.update_all(from(a in entry.table, where: a.id == ^entry.id),
        set: [allocation_seq: seq + 1]
      )

      seq + 1
    end)
  end

  # Cash and credit are ranked by the funding they came from, and `kind` keeps the unattributed
  # block's cash ahead of the unattributed block's credit.
  defp entries(group_id, records) do
    ranks = Map.new(records, &{&1.operation_id, &1.rank})
    credit = credit_rows(group_id)

    cash_entries =
      for {id, payment_operation_id} <- cash_rows(group_id) do
        %{
          table: "cash_allocations",
          id: id,
          rank: Map.get(ranks, payment_operation_id, @unattributed),
          kind: 0
        }
      end

    credit_ranks = credit_ranks(credit, records)

    credit_entries =
      for row <- credit do
        %{
          table: "credit_applications",
          id: row.id,
          rank: Map.get(credit_ranks, row.id, @unattributed),
          kind: 1
        }
      end

    cash_entries ++ credit_entries
  end

  defp cash_rows(group_id) do
    Repo.all(
      from a in "cash_allocations",
        where: a.group_id == ^group_id,
        order_by: [asc: a.id],
        select: {a.id, a.payment_operation_id}
    )
  end

  defp credit_rows(group_id) do
    Repo.all(
      from a in "credit_applications",
        where: a.group_id == ^group_id,
        order_by: [asc: a.id],
        select: %{id: a.id, amount_cents: a.amount_cents}
    )
  end

  # An application only knows how much credit it drew, so the recorded credit operations are
  # matched to the applications by amount from the most recent operation back. What no operation
  # claims is the unattributed credit the group was funded with before records existed.
  defp credit_ranks(rows, records) do
    records = records |> Enum.filter(&(&1.type == "apply_hotel_credit")) |> Enum.reverse()

    claim(Enum.reverse(rows), records, %{})
  end

  defp claim([], _records, ranks), do: ranks
  defp claim(_rows, [], ranks), do: ranks

  defp claim(rows, [record | records], ranks) do
    {claimed, rest} = take(rows, record.amount_cents, [])
    claim(rest, records, Enum.reduce(claimed, ranks, &Map.put(&2, &1.id, record.rank)))
  end

  defp take(rows, amount_cents, claimed) when amount_cents <= 0, do: {claimed, rows}
  defp take([], _amount_cents, claimed), do: {claimed, []}

  defp take([row | rows], amount_cents, claimed),
    do: take(rows, amount_cents - row.amount_cents, [row | claimed])

  # The durable records of applied funding, grouped by the group they funded and ranked by the
  # order they were committed in.
  defp funding_records do
    Repo.all(
      from r in "partner_operations",
        where: r.type in @funding_types,
        order_by: [asc: r.id],
        select: %{operation_id: r.operation_id, type: r.type, result: r.result}
    )
    |> Enum.with_index()
    |> Enum.flat_map(&funding_record/1)
    |> Enum.group_by(& &1.group_id)
  end

  defp funding_record({record, rank}) do
    result = Journal.decode_result(record.result)

    if result["status"] == "applied" and is_binary(result["group_id"]) and
         is_integer(result["amount_cents"]) do
      [
        %{
          operation_id: record.operation_id,
          type: record.type,
          group_id: result["group_id"],
          amount_cents: result["amount_cents"],
          rank: rank
        }
      ]
    else
      []
    end
  end
end
