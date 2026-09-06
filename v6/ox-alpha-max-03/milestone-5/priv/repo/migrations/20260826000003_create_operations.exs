defmodule GroupStay.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    create table(:operations, primary_key: false) do
      # `seq` is the durable commit-order marker: SQLite assigns it from a
      # monotonically increasing counter as records are first committed.
      add :seq, :integer, primary_key: true
      add :operation_id, :text, null: false
      add :type, :text
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operations, [:operation_id])
  end
end
