defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create index(:operations, [:type], where: "type = 'start_finance_reporting'")

    create table(:finance_entries) do
      add :operation_id, :text, null: false
      add :posted_on, :date, null: false
      add :property_id, :text
      add :classification, :text, null: false
      add :amount_cents, :bigint, null: false
    end

    create index(:finance_entries, [:posted_on])
  end
end
