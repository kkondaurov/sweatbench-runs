defmodule GroupStay.FinancePeriodCloseMigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "a release-06 reporting database upgrades without changing existing events" do
    database =
      Path.join(
        System.tmp_dir!(),
        "group-stay-period-close-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {UpgradeRepo,
       database: database, pool: DBConnection.ConnectionPool, pool_size: 1, journal_mode: :delete}
    )

    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_825_050_000)

    sql!("""
    INSERT INTO finance_reporting (id, starts_on, opening_credit_liability_cents)
    VALUES (1, '2027-01-01', 700)
    """)

    sql!("""
    INSERT INTO finance_cash_movements
      (operation_id, posting_on, property_id, received_cents)
    VALUES ('cash', '2027-01-02', 'hotel', 300)
    """)

    sql!("""
    INSERT INTO finance_credit_movements
      (operation_id, posting_on, issued_cents)
    VALUES ('credit', '2027-01-02', 400)
    """)

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_825_060_000)

    assert sql!("""
           SELECT starts_on, opening_credit_liability_cents, closed_through
             FROM finance_reporting
            WHERE id = 1
           """).rows == [["2027-01-01", 700, nil]]

    assert sql!("""
           SELECT operation_id, posting_on, property_id, received_cents, late_adjustment
             FROM finance_cash_movements
           """).rows == [["cash", "2027-01-02", "hotel", 300, 0]]

    assert sql!("""
           SELECT operation_id, posting_on, issued_cents, late_adjustment
             FROM finance_credit_movements
           """).rows == [["credit", "2027-01-02", 400, 0]]

    assert %{rows: []} =
             sql!("SELECT posting_on, amount_cents, late_adjustment FROM finance_credit_expiries")
  end

  defp sql!(statement), do: Ecto.Adapters.SQL.query!(UpgradeRepo, statement, [])
end
