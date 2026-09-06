defmodule GroupStay.DurableOperationsPersistenceTest do
  use ExUnit.Case, async: false

  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo, Reservations}

  test "upgrades a populated cancellation-economics database without reconstructing audit records" do
    directory =
      Path.expand("../../tmp/durable-upgrade-#{System.unique_integer([:positive])}", __DIR__)

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
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_001, log: false)

    Repo.insert!(%Group{
      group_id: "legacy",
      guest_id: "guest",
      property_id: "hotel",
      revision: 7,
      booked_on: ~D[2027-01-01],
      arrival_on: ~D[2027-06-01],
      departure_on: ~D[2027-06-02],
      rate_plan: "flexible",
      policy_version: "flex-30",
      rooms: [%{"room_id" => "r", "nightly_rate_cents" => 10000}],
      lodging_total_cents: 10000,
      deposit_due_cents: 2000,
      deposit_paid_cents: 150,
      cash_paid_cents: 100,
      credit_paid_cents: 50
    })

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest",
        source_operation_id: "old-cancellation",
        remaining_cents: 60,
        expires_on: ~D[2028-01-01]
      })

    Repo.insert!(%CreditAllocation{group_id: "legacy", credit_lot_id: lot.id, amount_cents: 50})

    before =
      {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation),
       Reservations.ledger(~D[2027-01-01])}

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_905_000_002]

    assert {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation),
            Reservations.ledger(~D[2027-01-01])} == before

    assert Repo.all(Operation) == []
    assert Reservations.get_operation("old-cancellation") == nil

    operation = %{
      "operation_id" => "new-cancellation",
      "type" => "cancel_group",
      "group_id" => "legacy",
      "occurred_on" => "2027-05-02",
      "expected_revision" => 7,
      "refund_method" => "hotel_credit"
    }

    assert [%{revision: 8, credit_issued_cents: 110}] = results = Reservations.submit([operation])
    assert Reservations.guest_credit("guest", ~D[2027-05-02]).available_cents == 220
    records = Repo.all(Operation)

    # Close every SQLite connection, then reopen the same file through a new pool.
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.submit([operation]) == results
    assert Repo.all(Operation) == records
    assert Reservations.get_group("legacy").revision == 8
    assert Reservations.ledger(~D[2027-05-02]).credit_liability_cents == 220
    stop_supervised!(Repo)
  end

  @tag timeout: 60_000
  test "audit and exact applied and rejected results survive separate application processes" do
    directory =
      Path.expand("../../tmp/durable-restart-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> GroupStay.TestFiles.remove_directory!(directory) end)
    script = Path.expand("../support/durable_restart.exs", __DIR__)

    for phase <- ["write", "read"] do
      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-start", script, phase, directory],
          env: [
            {"MIX_ENV", "test"},
            {"GROUP_STAY_DATABASE_PATH", Path.join(directory, "groups.db")},
            {"PHX_SERVER", nil},
            {"ERL_FLAGS", "+S 2:2"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "durable #{phase} verified"
    end
  end
end
