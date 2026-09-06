defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:cash_payment_dispositions) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_dispositions, [:cash_payment_id, :group_id, :kind])
    create index(:cash_payment_dispositions, [:group_id])

    for {column, kind} <- [
          {:refunded_cents, "refunded"},
          {:retained_cents, "retained"},
          {:converted_cents, "converted"}
        ] do
      execute("""
      INSERT INTO cash_payment_dispositions
        (cash_payment_id, group_id, kind, amount_cents, inserted_at, updated_at)
      SELECT id, group_id, '#{kind}', #{column}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cash_payments
      WHERE #{column} > 0
      """)
    end
  end

  def down do
    drop table(:cash_payment_dispositions)

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end
  end
end
