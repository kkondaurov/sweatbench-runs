defmodule GroupStay.DepositTransferBackfill do
  @moduledoc false

  # Called by the deposit-transfer migration. Allocation order did not need a
  # cross-kind identity before transfers existed, so reconstruct it from the
  # funding order and the room-fill order established by the previous release.
  def run(repo) do
    backfill_allocation_order(repo)
    backfill_group_dispositions(repo)
  end

  defp backfill_allocation_order(repo) do
    allocations =
      rows(repo, """
      SELECT 'cash', allocation.id, allocation.funding_order, room.group_record_id,
             room.position, allocation.rowid
      FROM cash_allocations allocation
      JOIN rooms room ON room.id = allocation.room_record_id
      UNION ALL
      SELECT 'credit', allocation.id, allocation.funding_order, room.group_record_id,
             room.position, allocation.rowid
      FROM credit_allocations allocation
      JOIN rooms room ON room.id = allocation.room_record_id
      """)
      |> Enum.sort_by(fn [kind, _id, funding_order, group_id, position, rowid] ->
        {funding_order, group_id, kind_order(kind), position, rowid}
      end)

    allocations
    |> Enum.with_index(1)
    |> Enum.each(fn {[kind, id, _funding_order, _group_id, _position, _rowid], order} ->
      table = if kind == "cash", do: "cash_allocations", else: "credit_allocations"
      repo.query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order, id])
    end)
  end

  defp backfill_group_dispositions(repo) do
    now = timestamp()

    rows(repo, """
    SELECT id, group_record_id, refunded_cents, retained_cents,
           converted_to_credit_cents
    FROM cash_payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)
    |> Enum.each(fn [payment_id, group_id, refunded, retained, converted] ->
      repo.insert_all("cash_payment_group_dispositions", [
        %{
          id: Ecto.UUID.generate(),
          cash_payment_id: payment_id,
          group_record_id: group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted,
          inserted_at: now,
          updated_at: now
        }
      ])
    end)
  end

  defp kind_order("cash"), do: 0
  defp kind_order("credit"), do: 1
  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp rows(repo, sql), do: repo.query!(sql).rows
end
