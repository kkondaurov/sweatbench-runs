defmodule GroupStay.FinancePeriodCloseMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.{CreditLot, FinanceReporting, Operation, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Entry, Opening}

  test "upgrading populated daily reporting preserves entries and closes durably across database restarts" do
    directory =
      Path.expand("../../tmp/period-upgrade-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> GroupStay.TestFiles.remove_directory!(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_005, log: false)

    Reservations.submit([
      %{
        "operation_id" => "open",
        "type" => "open_group",
        "group_id" => "a",
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2030-06-01",
        "departure_on" => "2030-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 1000}]
      },
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "a",
        "occurred_on" => "2027-01-01",
        "amount_cents" => 100
      }
    ])

    Repo.insert!(%CreditLot{
      guest_id: "guest",
      source_operation_id: "legacy",
      remaining_cents: 60,
      expires_on: ~D[2028-01-01]
    })

    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-01"
    }

    Repo.insert!(%Operation{
      operation_id: "start",
      type: "start_finance_reporting",
      payload: start,
      result: %{"operation_id" => "start", "status" => "applied", "starts_on" => "2027-01-01"}
    })

    Repo.insert!(%Opening{
      id: 1,
      starts_on: ~D[2027-01-01],
      cash: %{"hotel" => 100},
      credit_liability_cents: 60
    })

    # Seed the previous release's entry shape, which has no late-adjustment column.
    Repo.insert_all("finance_entries", [
      %{
        operation_id: "start",
        posted_on: "2028-01-02",
        property_id: nil,
        classification: "expired_cents",
        amount_cents: 60
      }
    ])

    before =
      {Repo.all(Operation), Repo.all(Opening), Reservations.get_group("a"),
       Reservations.ledger(~D[2028-01-02])}

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_905_000_006]

    assert {Repo.all(Operation), Repo.all(Opening), Reservations.get_group("a"),
            Reservations.ledger(~D[2028-01-02])} == before

    assert [%Entry{late_adjustment: false, posted_on: ~D[2028-01-02], amount_cents: 60}] =
             Repo.all(Entry)

    assert {:ok, %{status: "open", credit: %{movements: %{"expired_cents" => 60}}}} =
             FinanceReporting.daily_report("2028-01-02")

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2028-01-02"
    }

    assert [%{status: "applied"}] = result = Reservations.submit([close])
    {:ok, closed} = FinanceReporting.daily_report("2028-01-02")
    bytes = Jason.encode!(closed)
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.submit([close]) == result
    assert {:ok, ^closed} = FinanceReporting.daily_report("2028-01-02")

    Reservations.submit([
      %{
        "operation_id" => "late",
        "type" => "record_cash_payment",
        "group_id" => "a",
        "occurred_on" => "2027-01-01",
        "amount_cents" => 25
      }
    ])

    assert {:ok, unchanged} = FinanceReporting.daily_report("2028-01-02")
    assert Jason.encode!(unchanged) == bytes

    assert {:ok,
            %{
              cash: [%{opening_held_cents: 100, closing_held_cents: 125}],
              late_adjustments: %{cash: [%{movements: %{"received_cents" => 25}}]}
            }} = FinanceReporting.daily_report("2028-01-03")
  end
end
