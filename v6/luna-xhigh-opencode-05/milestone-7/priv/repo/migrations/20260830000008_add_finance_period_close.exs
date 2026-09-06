defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_postings) do
      add :occurred_on, :date
    end

    flush()
    backfill_posting_dates()

    create table(:finance_closes) do
      add :reporting_id, references(:finance_reporting, on_delete: :delete_all), null: false
      add :operation_id, :string, null: false
      add :period_end_on, :date, null: false
    end

    create unique_index(:finance_closes, [:operation_id])
    create index(:finance_closes, [:reporting_id, :period_end_on])

    create table(:finance_daily_reports) do
      add :reporting_id, references(:finance_reporting, on_delete: :delete_all), null: false
      add :report_on, :date, null: false
      add :data, :text, null: false
    end

    create unique_index(:finance_daily_reports, [:reporting_id, :report_on])
  end

  def down do
    drop table(:finance_daily_reports)
    drop table(:finance_closes)

    alter table(:finance_postings) do
      remove :occurred_on
    end
  end

  defp backfill_posting_dates do
    repo().query!("SELECT id, operation_id, posting_on FROM finance_postings", []).rows
    |> Enum.each(fn [id, operation_id, posting_on] ->
      occurred_on =
        case repo().query!(
               "SELECT payload FROM operation_records WHERE operation_id = ?",
               [operation_id]
             ).rows do
          [[payload]] ->
            case Jason.decode(payload) do
              {:ok, %{"occurred_on" => date}} when is_binary(date) ->
                case Date.from_iso8601(date) do
                  {:ok, _date} -> date
                  {:error, _reason} -> posting_on
                end

              _ ->
                posting_on
            end

          _ ->
            posting_on
        end

      repo().query!("UPDATE finance_postings SET occurred_on = ? WHERE id = ?", [occurred_on, id])
    end)
  end
end
