defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:payment_dispositions) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:payment_group_dispositions) do
      add :payment_disposition_id, references(:payment_dispositions, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_group_dispositions, [:payment_disposition_id, :group_id])
    create index(:payment_group_dispositions, [:group_id])

    execute("""
    INSERT INTO payment_group_dispositions
      (payment_disposition_id, group_id, refunded_cents, retained_cents, converted_cents,
       inserted_at, updated_at)
    SELECT id, group_id, refunded_cents, retained_cents, converted_cents,
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_dispositions
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_cents > 0
    """)
  end

  def down do
    drop table(:payment_group_dispositions)

    alter table(:payment_dispositions) do
      remove :participated_in_transfer
    end
  end
end
