defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  # Durable period closes: each successful close records its cutoff date and
  # a published snapshot of every daily report through that cutoff, so closed
  # reports stay byte-for-byte stable. Movements posted after a close flag
  # whether their posting date was moved forward by the cutoff, which the
  # report exposes as late adjustments.

  def change do
    create table(:finance_closes) do
      add :period_end_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_closes, [:period_end_on])

    create table(:finance_closed_reports) do
      add :date, :date, null: false
      # The published report `data` value, exactly as first rendered.
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_closed_reports, [:date])

    alter table(:finance_movements) do
      # Whether the posting date was moved forward by a period close.
      add :late, :boolean, null: false, default: false
    end
  end
end
