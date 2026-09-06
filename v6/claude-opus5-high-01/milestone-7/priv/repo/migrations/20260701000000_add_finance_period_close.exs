defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  @moduledoc """
  Lets finance sign a period off and keeps what arrives afterwards visible.

  A close records the cutoff it published through. From then on an operation
  whose finance effects would have landed in the closed period posts them on the
  first open day instead, and each movement remembers whether a close is what put
  it there, so a report can show those movements as late adjustments beside the
  day's ordinary ones.

  Databases from earlier releases have closed nothing and moved nothing forward,
  so the new column starts false for every movement already written.
  """

  use Ecto.Migration

  def change do
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_period_closes, [:period_end_on])
    create unique_index(:finance_period_closes, [:operation_id])

    alter table(:finance_cash_movements) do
      add :late, :boolean, null: false, default: false
    end

    alter table(:finance_credit_movements) do
      add :late, :boolean, null: false, default: false
    end
  end
end
