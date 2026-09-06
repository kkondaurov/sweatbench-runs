defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  # The finance-reporting inception point, the posting-dated movement stream
  # the daily report reads, and the settled-group attribution that lets
  # corrections follow settled cash to the property where it settled.

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      # Cash held per property as a JSON object, snapshotted when reporting
      # starts: the opening position of every later report.
      add :opening_cash, :text, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_movements) do
      add :scope, :string, null: false
      # Null for company-wide credit movements.
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      # The later of the operation's occurred_on and reporting's starts_on.
      add :posting_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_on])

    create table(:payment_settlements) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:payment_settlements, [:payment_operation_id])
  end
end
