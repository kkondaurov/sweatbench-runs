defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:payment_transfer_participations) do
      add :payment_funding_id, references(:payment_fundings, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:payment_transfer_participations, [:payment_funding_id])

    create table(:payment_dispositions) do
      add :payment_funding_id, references(:payment_fundings, on_delete: :restrict), null: false
      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_dispositions, [:payment_funding_id, :group_id])
    create index(:payment_dispositions, [:group_id])

    execute("""
    INSERT INTO payment_dispositions
      (payment_funding_id, group_id, refunded_cents, retained_cents,
       converted_to_credit_cents, inserted_at, updated_at)
    SELECT id, group_id, refunded_cents, retained_cents,
           converted_to_credit_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_fundings
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)

    flush()
    GroupStay.Operations.backfill_transfer_allocation_order!()
  end

  def down do
    drop table(:payment_dispositions)
    drop table(:payment_transfer_participations)
  end
end
