defmodule GroupStay.Repo.Migrations.CreateFinanceReporting do
  use Ecto.Migration

  def change do
    # The durable reporting inception point: one row, created by the first
    # applied `start_finance_reporting` operation. `snapshot` holds the
    # financial opening position captured immediately before that operation
    # was processed: held cash per property and every credit lot's balance.
    create table(:finance_reporting, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :snapshot, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:start_operation_id])
  end
end
