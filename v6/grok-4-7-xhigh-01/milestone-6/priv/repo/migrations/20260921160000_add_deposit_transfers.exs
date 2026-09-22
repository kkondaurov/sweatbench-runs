defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    add_column_if_missing("cash_allocations", "order_lo")
    add_column_if_missing("credit_allocations", "order_lo")

    create table(:transferred_payments, primary_key: false) do
      add :operation_id, :string, primary_key: true

      timestamps(type: :utc_datetime)
    end

    flush()

    GroupStay.Funding.OrderBackfill.run()
  end

  def down do
    drop table(:transferred_payments)
  end

  defp add_column_if_missing(table, column) do
    unless column_exists?(table, column) do
      execute "ALTER TABLE #{table} ADD COLUMN #{column} INTEGER"
    end
  end

  defp column_exists?(table, column) do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM pragma_table_info('#{table}') WHERE name = '#{column}' LIMIT 1"
      )

    rows != []
  end
end
