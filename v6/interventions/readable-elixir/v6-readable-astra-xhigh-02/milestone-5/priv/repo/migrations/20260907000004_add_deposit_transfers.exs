defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end

    create table(:cash_settlements) do
      add :cash_payment_id, references(:cash_payments), null: false
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_settlements, [:cash_payment_id, :group_id])
    create index(:cash_settlements, [:group_id])

    # Before transfers, cash could settle only at its original payment group.
    execute """
    INSERT INTO cash_settlements
      (cash_payment_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents)
    SELECT id, group_id, refunded_cents, retained_cents, converted_to_credit_cents
    FROM cash_payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """
  end

  def down do
    transferred? =
      repo().query!("SELECT result FROM operations WHERE type = 'transfer_deposit'").rows
      |> Enum.any?(fn [result] -> Jason.decode!(result)["status"] == "applied" end)

    if transferred? do
      raise Ecto.MigrationError,
        message:
          "deposit transfers require a forward migration; downgrade would lose accounting history"
    end

    drop table(:cash_settlements)

    alter table(:cash_payments) do
      remove :transferred
    end
  end
end
