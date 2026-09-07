defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def change do
    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end

    create table(:payment_settlements) do
      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :string), null: false

      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :refunded_cents, :bigint, null: false, default: 0
      add :retained_cents, :bigint, null: false, default: 0
      add :converted_to_credit_cents, :bigint, null: false, default: 0
    end

    create unique_index(:payment_settlements, [:payment_operation_id, :group_id])

    # Before transfers, every payment settled exclusively in its original group.
    # Preserve those dispositions without replaying operations or changing totals.
    execute(
      """
      INSERT INTO payment_settlements
        (payment_operation_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents)
      SELECT payment_operation_id, original_group_id, refunded_cents, retained_cents,
             converted_to_credit_cents
      FROM cash_payments
      WHERE refunded_cents + retained_cents + converted_to_credit_cents > 0
      """,
      "DELETE FROM payment_settlements"
    )
  end
end
