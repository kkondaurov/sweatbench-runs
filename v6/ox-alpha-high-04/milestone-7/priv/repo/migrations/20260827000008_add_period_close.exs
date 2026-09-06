defmodule GroupStay.Repo.Migrations.AddPeriodClose do
  use Ecto.Migration

  def change do
    # One row per successful `close_finance_period` operation. Closes are
    # strictly increasing by `period_end_on`, so the latest row is the
    # current cutoff: every daily report through it is published, and
    # operations processed afterwards post on the first open day.
    create table(:finance_period_closes) do
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finance_period_closes, [:period_end_on])

    # Marks a journaled movement whose posting date was moved forward by a
    # close: the operation committed after the cutoff and its complete
    # finance effect posted on the first open day. The daily report splits
    # these rows into the `late_adjustments` block; ordinary movements keep
    # their own columns. Movements journaled before any close default to
    # false, which stays correct for a database upgraded in place.
    alter table(:finance_movements) do
      add :late_adjustment, :boolean, null: false, default: false
    end
  end
end
