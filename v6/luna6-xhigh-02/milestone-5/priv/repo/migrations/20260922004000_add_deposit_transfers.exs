defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end

    create table(:funding_allocation_orders) do
    end

    alter table(:room_cash_allocations) do
      add :allocation_order_id, :integer
    end

    alter table(:group_credit_allocations) do
      add :allocation_order_id, :integer
    end

    flush()
    backfill_allocation_order()

    create unique_index(:room_cash_allocations, [:allocation_order_id])
    create unique_index(:group_credit_allocations, [:allocation_order_id])
  end

  def down do
    drop_if_exists index(:group_credit_allocations, [:allocation_order_id])
    drop_if_exists index(:room_cash_allocations, [:allocation_order_id])

    alter table(:group_credit_allocations) do
      remove :allocation_order_id
    end

    alter table(:room_cash_allocations) do
      remove :allocation_order_id
    end

    drop table(:funding_allocation_orders)

    alter table(:cash_payments) do
      remove :transferred
    end
  end

  defp backfill_allocation_order do
    operation_order =
      repo().query!("SELECT operation_id, id FROM operation_records").rows
      |> Map.new(fn [operation_id, id] -> {operation_id, id} end)

    cash =
      repo().query!(
        "SELECT id, group_id, payment_operation_id FROM room_cash_allocations ORDER BY id"
      ).rows
      |> Enum.map(fn [id, group_id, source_id] ->
        {id, group_id, source_id, :cash}
      end)

    credit =
      repo().query!(
        "SELECT id, group_id, source_operation_id FROM group_credit_allocations ORDER BY id"
      ).rows
      |> Enum.map(fn [id, group_id, source_id] ->
        {id, group_id, source_id, :credit}
      end)

    (cash ++ credit)
    |> Enum.sort_by(fn {id, group_id, source_id, kind} ->
      case source_id do
        nil ->
          {group_id, 0, if(kind == :cash, do: 0, else: 1), 0, id}

        _ ->
          {group_id, 1, 0, Map.get(operation_order, source_id, 9_223_372_036_854_775_807), id}
      end
    end)
    |> Enum.each(fn {allocation_id, _group_id, _source_id, kind} ->
      repo().query!("INSERT INTO funding_allocation_orders DEFAULT VALUES")
      [[order_id]] = repo().query!("SELECT max(id) FROM funding_allocation_orders").rows

      table = if kind == :cash, do: "room_cash_allocations", else: "group_credit_allocations"

      repo().query!("UPDATE #{table} SET allocation_order_id = ? WHERE id = ?", [
        order_id,
        allocation_id
      ])
    end)
  end
end
