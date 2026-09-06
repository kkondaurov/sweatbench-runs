defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database upgrades policies and preserves balances and revisions" do
    path = Path.expand("migration-test-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2026-12-31", "advance_purchase"}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-03-01', '2027-03-02', ?, 'active', 7, '[]', 1000, 200, 100)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

    assert UpgradeRepo.aggregate(GroupStay.Operation, :count) == 0

    for {id, policy} <- [
          {"old", "flex-14"},
          {"new", "flex-30"},
          {"advance", "advance-nonrefundable"}
        ] do
      group = UpgradeRepo.get!(GroupStay.Group, id)
      assert group.policy_version == policy
      assert group.revision == 7
      assert group.deposit_paid_cents == 100
      assert group.cash_paid_cents == 100
      assert group.credit_paid_cents == 0
      assert group.credit_allocations == []
    end
  end

  test "room upgrade puts legacy funding first and durable types in commit order, preserving balances" do
    path = Path.expand("room-migration-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_002, log: false)
    rooms = for i <- 0..2, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 100}
    sql = fn statement, params -> Ecto.Adapters.SQL.query!(UpgradeRepo, statement, params) end

    for {id, remaining} <- [{1, 12}, {2, 5}] do
      sql.(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, ?, '2027-10-01')",
        [id, "lot-#{id}", remaining]
      )
    end

    allocations = [%{"lot_id" => 1, "amount_cents" => 8}, %{"lot_id" => 2, "amount_cents" => 15}]

    sql.(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_paid_cents, credit_paid_cents, credit_allocations)
      VALUES ('g', 'guest', 'hotel', '2026-10-01', '2027-03-01', '2027-03-02', 'flexible', 'flex-14', 'active', 9, ?, 300, 60, 45, 22, 23, ?)
      """,
      [Jason.encode!(rooms), Jason.encode!(allocations)]
    )

    # Identifier spelling and event dates deliberately disagree with commit order.
    for {id, type, day} <- [
          {"z-credit", "apply_hotel_credit", "2026-12-01"},
          {"a-cash", "record_cash_payment", "2026-10-01"}
        ] do
      result = %{"group_id" => "g", "status" => "applied", "amount_cents" => 15}

      submission = %{
        "type" => type,
        "group_id" => "g",
        "occurred_on" => day,
        "amount_cents" => 15
      }

      sql.(
        "INSERT INTO operations (operation_id, type, submission, result) VALUES (?, ?, ?, ?)",
        [id, type, Jason.encode!(submission), Jason.encode!(result)]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_003, log: false)
    before_transfer_upgrade = UpgradeRepo.get!(GroupStay.Group, "g")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    upgraded = UpgradeRepo.get!(GroupStay.Group, "g")

    assert %{
             upgraded
             | funding_allocations:
                 Enum.map(
                   upgraded.funding_allocations,
                   &Map.delete(&1, "allocation_order")
                 )
           } == before_transfer_upgrade

    assert Enum.map(upgraded.funding_allocations, & &1["allocation_order"]) ==
             Enum.to_list(1..length(upgraded.funding_allocations))

    group = UpgradeRepo.get!(GroupStay.Group, "g")
    assert group.revision == 9

    assert {group.cash_paid_cents, group.credit_paid_cents, group.deposit_paid_cents} ==
             {22, 23, 45}

    assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {7, 13},
             {10, 10},
             {5, 0}
           ]

    assert Enum.map(UpgradeRepo.all(GroupStay.CreditLot), & &1.remaining_cents) == [12, 5]

    assert Enum.map(group.funding_allocations, & &1["payment_operation_id"]) == [
             nil,
             nil,
             nil,
             nil,
             "a-cash",
             "a-cash"
           ]

    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      assert {:ok, %{"held_cents" => 15, "recorded_cents" => 15}} =
               GroupStay.Reservations.get_payment("a-cash")

      assert [%{"status" => "applied", "revision" => 10}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "reduce",
                   "type" => "reduce_cash_payment",
                   "payment_operation_id" => "a-cash",
                   "amount_cents" => 7,
                   "occurred_on" => "2026-12-02"
                 }
               ])

      assert Enum.map(GroupStay.Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [
               7,
               8,
               0
             ]
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end

  test "cancelled payment history and converted entitlements survive upgrade" do
    path = Path.expand("settled-migration-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Path.expand("priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_002, log: false)
    sql = fn statement, params -> Ecto.Adapters.SQL.query!(UpgradeRepo, statement, params) end
    rooms = [%{"room_id" => "r", "nightly_rate_cents" => 100}]

    for {id, refunded, retained, converted} <- [
          {"refund", 10, 0, 0},
          {"retain", 0, 10, 0},
          {"convert", 0, 0, 10}
        ] do
      sql.(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_paid_cents, refunded_cents, retained_cents, converted_cents)
        VALUES (?, 'guest', 'hotel', '2026-10-01', '2027-03-01', '2027-03-02', 'flexible', 'flex-14', 'cancelled', 3, ?, 100, 0, 0, 0, ?, ?, ?)
        """,
        [id, Jason.encode!(rooms), refunded, retained, converted]
      )

      for {operation_id, type, amount} <- [
            {"pay-#{id}", "record_cash_payment", 5},
            {"cancel-#{id}", "cancel_group", 0}
          ] do
        result = %{"group_id" => id, "status" => "applied", "amount_cents" => amount}

        sql.(
          "INSERT INTO operations (operation_id, type, submission, result) VALUES (?, ?, '{}', ?)",
          [operation_id, type, Jason.encode!(result)]
        )
      end
    end

    sql.(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest', 'cancel-convert', 11, '2027-10-01')",
      []
    )

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    [lot] = UpgradeRepo.all(GroupStay.CreditLot)
    assert lot.entitlements == %{"" => 6, "pay-convert" => 5}
    assert lot.remaining_cents == 11
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      for {id, disposition} <- [
            {"refund", "refunded_cents"},
            {"retain", "retained_cents"},
            {"convert", "converted_to_credit_cents"}
          ] do
        {:ok, statement} = GroupStay.Reservations.get_payment("pay-#{id}")
        assert statement[disposition] == 5
        assert statement["held_cents"] == 0
      end

      assert [%{"charged_back_cents" => 5, "revision" => 4}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "charge",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => "pay-convert",
                   "occurred_on" => "2026-12-02"
                 }
               ])

      assert GroupStay.Reservations.guest_credit("guest", ~D[2026-12-02]).available_cents == 6
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end
end
