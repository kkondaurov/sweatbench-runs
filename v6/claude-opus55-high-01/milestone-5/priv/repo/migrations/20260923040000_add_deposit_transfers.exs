defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  # This migration orders existing funding with its own copy of the room-accounting rules, so it
  # keeps working as the application's modules evolve.

  def up do
    for table <- [:cash_allocations, :credit_applications] do
      alter table(table) do
        # One sequence across cash and credit: the order in which funding was allocated.
        add :allocation_seq, :integer, null: false, default: 0
        # The transfer that moved this funding, on both the moved-out and the moved-in rows.
        add :transfer_operation_id, :string
      end
    end

    create index(:cash_allocations, [:allocation_seq])
    create index(:credit_applications, [:allocation_seq])

    flush()

    backfill_allocation_order()
  end

  def down do
    drop index(:credit_applications, [:allocation_seq])
    drop index(:cash_allocations, [:allocation_seq])

    for table <- [:cash_allocations, :credit_applications] do
      alter table(table) do
        remove :transfer_operation_id
        remove :allocation_seq
      end
    end
  end

  ## Backfill
  #
  # Existing funding is ordered as room accounting allocated it: each group's unattributed senior
  # block (its cash, then its credit in consumption order), then funding with durable records in
  # commit order. Rows split from one allocation keep its place.

  defp backfill_allocation_order do
    records = durable_funding()

    record_order =
      for %{type: "record_cash_payment"} = record <- records,
          into: %{},
          do: {record.operation_id, record.id}

    %{rows: cash} =
      repo().query!("SELECT id, group_ref, payment_operation_id FROM cash_allocations")

    cash_keys =
      for [id, group_ref, payment] <- cash do
        key =
          case record_order do
            %{^payment => record_id} -> {1, record_id, 0, id}
            %{} -> {0, group_ref, 0, id}
          end

        {"cash_allocations", id, key}
      end

    durable_credit = durable_credit_applications(records)

    %{rows: credit} = repo().query!("SELECT id, group_ref FROM credit_applications")

    credit_keys =
      for [id, group_ref] <- credit do
        key =
          case durable_credit do
            %{^id => record_id} -> {1, record_id, 1, id}
            %{} -> {0, group_ref, 1, id}
          end

        {"credit_applications", id, key}
      end

    (cash_keys ++ credit_keys)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.with_index(1)
    |> Enum.each(fn {{table, id, _key}, seq} ->
      repo().query!("UPDATE #{table} SET allocation_seq = ? WHERE id = ?", [seq, id])
    end)
  end

  # Applied cash payments and credit applications with durable records, in commit order.
  defp durable_funding do
    %{rows: rows} =
      repo().query!("""
      SELECT id, operation_id, type, payload, result FROM operation_records
      WHERE status = 'applied' AND type IN ('record_cash_payment', 'apply_hotel_credit')
      ORDER BY id
      """)

    for [id, operation_id, type, payload, result] <- rows do
      submitted = Jason.decode!(payload)
      result = Jason.decode!(result)

      %{
        id: id,
        operation_id: operation_id,
        type: type,
        group_id: result["group_id"] || submitted["group_id"],
        amount: result["amount_cents"] || submitted["amount_cents"]
      }
    end
  end

  # Credit application rows created by durable `apply_hotel_credit` records, as `%{row_id =>
  # record_id}`. An earlier release may have used the same operation identifier on the same group,
  # so each record claims its most recent rows up to its recorded amount; settlement splits rows
  # without changing their total.
  defp durable_credit_applications(records) do
    %{rows: rows} =
      repo().query!("""
      SELECT a.id, g.group_id, a.operation_id, a.amount_cents
      FROM credit_applications a JOIN groups g ON g.id = a.group_ref
      ORDER BY a.id DESC
      """)

    for %{type: "apply_hotel_credit"} = record <- records, reduce: %{} do
      claimed ->
        rows
        |> Enum.filter(fn [id, group_id, operation_id, _amount] ->
          group_id == record.group_id and operation_id == record.operation_id and
            not Map.has_key?(claimed, id)
        end)
        |> Enum.reduce_while({claimed, record.amount}, fn
          _row, {claimed, left} when left <= 0 ->
            {:halt, {claimed, left}}

          [id, _group_id, _operation_id, amount], {claimed, left} ->
            {:cont, {Map.put(claimed, id, record.id), left - amount}}
        end)
        |> elem(0)
    end
  end
end
