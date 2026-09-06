defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  @moduledoc """
  Daily finance reporting (docs/requests/06).

  `reporting_state` is a singleton row: reporting is off until a
  `start_finance_reporting` operation inserts it. It stores the `starts_on`
  date and the opening position captured immediately before that operation
  processed: held cash per property plus the credit liability as of the start
  date. The primary key is a fixed value so concurrent start operations race
  on one row.

  Every applied finance effect after reporting starts records one or more
  signed `finance_movements` rows with its posting date (the later of
  `occurred_on` and `starts_on`). Cash movements carry the property where the
  cash is held or was settled; credit movements are company-wide. Credit
  expiry is not a recorded movement: it is synthesized at report time from
  the lots' expiry dates, so a report shows expiry even on days without
  partner operations.

  A payment's settled buckets (refunded/retained/converted) gain a property
  attribution map so a later chargeback reclassifies them at the property
  where they were settled.
  """
  use Ecto.Migration

  def up do
    create table(:reporting_state, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps()
    end

    create table(:finance_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :posting_date, :date, null: false
      add :scope, :string, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_movements, [:posting_date])

    alter table(:payment_dispositions) do
      add :settled_locations, :map, null: false, default: %{}
    end
  end

  def down do
    alter table(:payment_dispositions) do
      remove :settled_locations
    end

    drop(index(:finance_movements, [:posting_date]))
    drop(table(:finance_movements))
    drop(table(:reporting_state))
  end
end
