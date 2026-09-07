defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:finance_reporting_inceptions, primary_key: false) do
      add :id, :integer, primary_key: true, null: false
      add :starts_on, :date, null: false
      add :opening_position, :map, null: false
    end

    create unique_index(:finance_reporting_inceptions, ["(1)"], name: :single_finance_inception)

    create table(:finance_reporting_entries) do
      add :operation_id, :string, null: false
      add :posted_on, :date, null: false
      add :property_id, :string
      add :movements, :map, null: false
    end

    create index(:finance_reporting_entries, [:posted_on])
    create index(:finance_reporting_entries, [:operation_id])
  end

  def down do
    # An existing start's durable result cannot recreate a deleted inception on
    # retry. Refuse to discard reporting history while retaining that result.
    if repo().query!("SELECT id FROM finance_reporting_inceptions LIMIT 1").rows != [] do
      raise Ecto.MigrationError, message: "cannot downgrade after finance reporting starts"
    end

    drop table(:finance_reporting_entries)
    drop table(:finance_reporting_inceptions)
  end
end
