defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    # Groups created by earlier releases only accepted cash, so the cash they
    # hold is exactly their recorded deposit payment.
    execute """
    UPDATE groups SET cash_paid_cents = deposit_paid_cents
    WHERE cash_paid_cents != deposit_paid_cents
    """

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps()
    end

    create index(:credit_lots, [:guest_id])

    create table(:credit_applications) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])
  end
end
