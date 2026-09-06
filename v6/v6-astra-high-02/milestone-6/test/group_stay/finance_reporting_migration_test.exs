defmodule GroupStay.FinanceReportingMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    FinanceReporting,
    Group,
    Repo,
    Reservations,
    RoomAccounting
  }

  test "upgrading preserves legacy balances and captures available and applied credit at durable inception" do
    directory =
      Path.expand("../../tmp/finance-upgrade-#{System.unique_integer([:positive])}", __DIR__)

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
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_004, log: false)

    [opening] =
      Reservations.submit([
        %{
          "operation_id" => "open",
          "type" => "open_group",
          "group_id" => "legacy",
          "guest_id" => "guest",
          "property_id" => "hotel",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2030-06-01",
          "departure_on" => "2030-06-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5000}]
        }
      ])

    assert opening.status == "applied"

    live =
      Repo.insert!(%CreditLot{
        guest_id: "guest",
        source_operation_id: "legacy-live",
        remaining_cents: 60,
        expires_on: ~D[2028-01-01]
      })

    expired =
      Repo.insert!(%CreditLot{
        guest_id: "guest",
        source_operation_id: "legacy-expired",
        remaining_cents: 70,
        expires_on: ~D[2026-12-31]
      })

    group = Repo.get!(Group, "legacy")

    funded =
      group
      |> RoomAccounting.fund(100, "cash", nil)
      |> RoomAccounting.fund(40, "credit", nil, live.id)
      |> RoomAccounting.fund(30, "credit", nil, expired.id)

    group |> Ecto.Changeset.change(RoomAccounting.totals(funded.rooms)) |> Repo.update!()
    RoomAccounting.sync_credit("legacy")
    tables = [Group, CreditLot, CreditAllocation, GroupStay.RoomAllocation, GroupStay.Operation]
    before = Enum.map(tables, &Repo.all/1)
    ledger = Reservations.ledger(~D[2027-01-01])
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_905_000_005]
    assert Enum.map(tables, &Repo.all/1) == before
    assert Reservations.ledger(~D[2027-01-01]) == ledger
    assert FinanceReporting.daily_report("2027-01-01") == {:error, "report_not_available"}

    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-01"
    }

    assert [%{status: "applied"}] = results = Reservations.submit([start])

    assert {:ok,
            %{
              cash: [%{opening_held_cents: 100, closing_held_cents: 100}],
              credit: %{opening_liability_cents: 130, closing_liability_cents: 130}
            }} = FinanceReporting.daily_report("2027-01-01")

    assert {:ok,
            %{
              credit: %{
                opening_liability_cents: 130,
                closing_liability_cents: 70,
                movements: %{"expired_cents" => 60}
              }
            }} = report = FinanceReporting.daily_report("2028-01-02")

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.submit([start]) == results
    assert FinanceReporting.daily_report("2028-01-02") == report
    assert Reservations.ledger(~D[2027-01-01]) == ledger
  end
end
