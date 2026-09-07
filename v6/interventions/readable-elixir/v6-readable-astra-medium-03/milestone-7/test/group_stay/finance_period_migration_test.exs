defmodule GroupStay.FinancePeriodMigrationTest do
  use ExUnit.Case, async: false
  alias GroupStay.{FinanceReporting, Repo, Reservations}

  test "upgrading existing reporting preserves opening positions and ordinary movements" do
    directory = Path.expand("tmp/finance-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "upgrade.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous = Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      GroupStay.TestDatabase.remove!(directory)
    end)

    migrations = GroupStay.TestDatabase.migrations()
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_907_230_000, log: false)

    Repo.query!("""
    INSERT INTO finance_reporting (id, starts_on, opening_cash, opening_credit_cents)
    VALUES (1, '2026-10-01', '{"hotel":100}', 50)
    """)

    Repo.query!("""
    INSERT INTO finance_movements (posted_on, property_id, classification, amount_cents)
    VALUES ('2026-10-01', 'hotel', 'received_cents', 25),
           ('2026-10-02', NULL, 'expired_cents', 50)
    """)

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    assert {:ok, %{status: "open", cash: [cash], late_adjustments: %{cash: []}}} =
             FinanceReporting.daily_report("2026-10-01")

    assert cash.opening_held_cents == 100
    assert cash.closing_held_cents == 125
    assert cash.movements["received_cents"] == 25

    assert [%{"status" => "applied"}] =
             Reservations.submit([
               %{
                 "operation_id" => "close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-02"
               }
             ])

    assert {:ok, %{status: "closed", credit: credit}} =
             FinanceReporting.daily_report("2026-10-02")

    assert credit.movements["expired_cents"] == 50
    assert credit.closing_liability_cents == 0
  end
end
