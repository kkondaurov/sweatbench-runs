defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:finance_reporting, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_lots, :map, null: false

      timestamps()
    end

    create table(:finance_movements, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_movements, [:posting_date])

    create table(:finance_lot_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :posting_date, :date, null: false
      add :lot_id, :string, null: false
      add :pool_delta_cents, :integer, null: false, default: 0
      add :applied_delta_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:finance_lot_events, [:lot_id, :posting_date])

    create table(:payment_group_settlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:payment_group_settlements, [:payment_operation_id, :group_id])

    execute(fn -> backfill_settlements() end)
  end

  def down do
    drop table(:payment_group_settlements)
    drop table(:finance_lot_events)
    drop table(:finance_movements)
    drop table(:finance_reporting)
  end

  # Settlements recorded before this release live only on the disposition
  # rows. Their settled cash is attributed to the disposition's original
  # group, matching the historical ledger behavior.
  defp backfill_settlements do
    repo = repo()

    """
    SELECT payment_operation_id, group_id, refunded_cents, retained_cents,
           converted_cents
    FROM payment_dispositions
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_cents > 0
    """
    |> query_rows(repo)
    |> Enum.each(fn [payment_operation_id, group_id, refunded, retained, converted] ->
      now = now_string()

      execute_parameters(
        repo,
        """
        INSERT INTO payment_group_settlements
          (id, payment_operation_id, group_id, refunded_cents, retained_cents,
           converted_cents, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          payment_operation_id,
          group_id,
          refunded,
          retained,
          converted,
          now,
          now
        ]
      )
    end)
  end

  defp now_string do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:microsecond)
    |> NaiveDateTime.to_iso8601()
    |> String.replace("T", " ")
  end

  defp query_rows(sql, repo) do
    Ecto.Adapters.SQL.query!(repo, sql, []).rows
  end

  defp execute_parameters(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
  end
end
