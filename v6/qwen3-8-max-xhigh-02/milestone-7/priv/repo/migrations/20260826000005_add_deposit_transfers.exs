defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  import Ecto.Query

  def change do
    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end

    create table(:cash_payment_settlements) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:cash_payment_settlements, [:cash_payment_id])
    create index(:cash_payment_settlements, [:group_id])
    create unique_index(:cash_payment_settlements, [:cash_payment_id, :group_id])

    flush()

    backfill_settlements()
  end

  # Funding could not cross groups before transfers existed, so every
  # settled disposition of a payment was recorded under the payment's own
  # group.
  defp backfill_settlements do
    payments =
      repo().all(
        from(p in "cash_payments",
          where: p.refunded_cents > 0 or p.retained_cents > 0 or p.converted_cents > 0,
          select: %{
            id: p.id,
            group_id: p.group_id,
            refunded_cents: p.refunded_cents,
            retained_cents: p.retained_cents,
            converted_cents: p.converted_cents
          }
        )
      )

    if payments != [] do
      now = NaiveDateTime.utc_now(:second)

      rows =
        Enum.map(payments, fn payment ->
          %{
            cash_payment_id: payment.id,
            group_id: payment.group_id,
            refunded_cents: payment.refunded_cents,
            retained_cents: payment.retained_cents,
            converted_cents: payment.converted_cents,
            inserted_at: now,
            updated_at: now
          }
        end)

      repo().insert_all("cash_payment_settlements", rows)
    end
  end
end
