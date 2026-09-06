defmodule GroupStay.Repo.Migrations.AddFinancePeriodClose do
  use Ecto.Migration

  def up do
    alter table(:finance_reporting) do
      add :closed_through_on, :date
    end

    # A valid cutoff of 9999-12-31 puts subsequent postings in year 10000.
    # Integer calendar days keep those internal dates ordered and loadable,
    # while preserving the original dates of every existing movement.
    replace_movements(:integer, fn on ->
      on |> Date.from_iso8601!() |> Date.to_gregorian_days()
    end)
  end

  def down do
    replace_movements(:date, fn day ->
      day |> Date.from_gregorian_days() |> Date.to_iso8601()
    end)

    alter table(:finance_reporting) do
      remove :closed_through_on
    end
  end

  # SQLite cannot alter a column's type. Copy the immutable rows, preserving
  # their identities and JSON amounts, and restore both indexes after the swap.
  defp replace_movements(date_type, convert) do
    create table(:finance_movements_next) do
      add :operation_id, :string, null: false
      add :posted_on, date_type, null: false
      add :cash, :map, null: false
      add :credit, :map, null: false

      if date_type == :integer do
        add :late_adjustment, :boolean, null: false, default: false
      end
    end

    flush()

    for [id, operation_id, on, cash, credit] <-
          repo().query!("SELECT id, operation_id, posted_on, cash, credit FROM finance_movements").rows do
      repo().query!(
        "INSERT INTO finance_movements_next (id, operation_id, posted_on, cash, credit) VALUES (?, ?, ?, ?, ?)",
        [id, operation_id, convert.(on), cash, credit]
      )
    end

    drop table(:finance_movements)
    rename table(:finance_movements_next), to: table(:finance_movements)
    create unique_index(:finance_movements, [:operation_id, :posted_on])
    create index(:finance_movements, [:posted_on])
  end
end
