defmodule GroupStay.Repo.Migrations.AddFinanceOpeningDispositions do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_opening_dispositions) do
      add :payment_operation_id, :string, null: false
      add :property_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create index(:finance_reporting_opening_dispositions, [:payment_operation_id])
  end
end
