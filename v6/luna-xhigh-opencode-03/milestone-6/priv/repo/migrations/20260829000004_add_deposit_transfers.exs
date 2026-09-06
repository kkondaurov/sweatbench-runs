defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
      add :transferred, :boolean, null: false, default: false
    end

    alter table(:group_credit_allocations) do
      add :allocation_order, :integer
    end

    flush()

    backfill_allocation_orders()

    create index(:cash_allocations, [:allocation_order])
    create index(:group_credit_allocations, [:allocation_order])
  end

  def down do
    drop index(:group_credit_allocations, [:allocation_order])
    drop index(:cash_allocations, [:allocation_order])

    alter table(:group_credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :transferred
      remove :allocation_order
    end
  end

  defp backfill_allocation_orders do
    operation_rows =
      repo().query!(
        "SELECT id, operation_id, operation_type, result_json " <>
          "FROM operation_records ORDER BY id"
      ).rows

    groups = repo().query!("SELECT id, group_id FROM groups ORDER BY id").rows

    Enum.reduce(groups, 1, fn [group_record_id, group_id], next_order ->
      cash_rows =
        repo().query!(
          "SELECT id, payment_operation_id FROM cash_allocations " <>
            "WHERE group_record_id = ? ORDER BY id",
          [group_record_id]
        ).rows

      credit_rows =
        repo().query!(
          "SELECT id, source_operation_id FROM group_credit_allocations " <>
            "WHERE group_record_id = ? ORDER BY id",
          [group_record_id]
        ).rows

      events = funding_events(group_id, operation_rows)

      {next_order, assigned_cash, assigned_credit} =
        Enum.reduce(events, {next_order, MapSet.new(), MapSet.new()}, fn {kind, source},
                                                                         {order, cash_ids,
                                                                          credit_ids} ->
          rows = if kind == :cash, do: cash_rows, else: credit_rows
          rows = Enum.filter(rows, fn [_row_id, row_source] -> row_source == source end)

          Enum.reduce(rows, {order, cash_ids, credit_ids}, fn [row_id, _source], acc ->
            set_allocation_order(kind, row_id, elem(acc, 0))
            {order, cash_ids, credit_ids} = acc

            if kind == :cash do
              {order + 1, MapSet.put(cash_ids, row_id), credit_ids}
            else
              {order + 1, cash_ids, MapSet.put(credit_ids, row_id)}
            end
          end)
        end)

      unassigned_rows =
        Enum.filter(cash_rows, fn [row_id, _source] ->
          not MapSet.member?(assigned_cash, row_id)
        end)
        |> Enum.map(&{:cash, &1})
        |> Kernel.++(
          Enum.filter(credit_rows, fn [row_id, _source] ->
            not MapSet.member?(assigned_credit, row_id)
          end)
          |> Enum.map(&{:credit, &1})
        )

      Enum.reduce(unassigned_rows, next_order, fn {kind, [row_id, _source]}, order ->
        set_allocation_order(kind, row_id, order)
        order + 1
      end)
    end)
  end

  defp funding_events(group_id, operation_rows) do
    legacy = [{:cash, nil}, {:credit, nil}]

    recorded =
      operation_rows
      |> Enum.flat_map(fn [_record_id, operation_id, operation_type, result_json] ->
        case Jason.decode(result_json) do
          {:ok, %{"status" => "applied", "group_id" => ^group_id}}
          when operation_type == "record_cash_payment" ->
            [{:cash, operation_id}]

          {:ok, %{"status" => "applied", "group_id" => ^group_id}}
          when operation_type == "apply_hotel_credit" ->
            [{:credit, operation_id}]

          _ ->
            []
        end
      end)

    legacy ++ recorded
  end

  defp set_allocation_order(:cash, row_id, order) do
    repo().query!("UPDATE cash_allocations SET allocation_order = ? WHERE id = ?", [order, row_id])
  end

  defp set_allocation_order(:credit, row_id, order) do
    repo().query!("UPDATE group_credit_allocations SET allocation_order = ? WHERE id = ?", [
      order,
      row_id
    ])
  end
end
