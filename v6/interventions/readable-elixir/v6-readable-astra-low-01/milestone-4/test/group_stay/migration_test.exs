defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier database upgrades booking policies without changing cash or revisions" do
    directory = Path.expand("tmp/migration-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(directory)

    repo =
      start_supervised!({UpgradeRepo, database: Path.join(directory, "upgrade.db"), pool_size: 1})

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      GroupStay.DatabaseFiles.remove!(directory)
    end)

    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_907_000_000, log: false)

    for {id, booked, plan} <- [
          {"old", "2026-12-31", "flexible"},
          {"new", "2027-01-01", "flexible"},
          {"advance", "2026-12-31", "advance_purchase"}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents, deposit_paid_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-04-01', '2028-04-02', ?, 'active', 3, '[{"room_id":"room","nightly_rate_cents":1000}]', 1000, 200, 100)
        """,
        [id, booked, plan]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

    assert UpgradeRepo.aggregate(GroupStay.Operations.Record, :count) == 0

    for {id, policy, cutoff} <- [
          {"old", "flex-14", ~D[2028-03-18]},
          {"new", "flex-30", ~D[2028-03-02]},
          {"advance", "advance-nonrefundable", nil}
        ] do
      group = UpgradeRepo.get!(GroupStay.Reservations.Group, id)

      assert %{
               policy_version: ^policy,
               refundable_until: ^cutoff,
               revision: 3,
               cash_paid_cents: 100,
               credit_paid_cents: 0
             } = GroupStay.Reservations.Group.public(group)
    end
  end

  test "room upgrade preserves balances and reconstructs senior funding before inbox commit order" do
    directory = Path.expand("tmp/rooms-migration-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(directory)

    repo =
      start_supervised!({UpgradeRepo, database: Path.join(directory, "upgrade.db"), pool_size: 1})

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      GroupStay.DatabaseFiles.remove!(directory)
    end)

    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_907_000_002, log: false)
    rooms = Enum.map(0..2, &%{"room_id" => "r#{&1}", "nightly_rate_cents" => 500})

    group =
      UpgradeRepo.insert!(%GroupStay.Reservations.Group{
        group_id: "mixed",
        guest_id: "guest",
        property_id: "hotel",
        booked_on: ~D[2027-01-01],
        arrival_on: ~D[2027-06-01],
        departure_on: ~D[2027-06-02],
        rate_plan: "flexible",
        policy_version: "flex-30",
        rooms: rooms,
        lodging_total_cents: 1500,
        deposit_due_cents: 300,
        deposit_paid_cents: 280,
        credit_paid_cents: 120,
        revision: 5
      })

    for {id, remaining} <- [{1, 10}, {2, 20}] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, ?, '2028-01-01')",
        [id, "lot-#{id}", remaining]
      )
    end

    # Original consumption order: senior 30, recorded 10, recorded 80.
    for {lot, amount} <- [{1, 30}, {1, 10}, {2, 80}] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        "INSERT INTO credit_allocations (group_id, lot_id, amount_cents) VALUES ('mixed', ?, ?)",
        [lot, amount]
      )
    end

    records =
      for {type, id, amount, on} <- [
            {"apply_hotel_credit", "credit", 90, "2027-02-10"},
            {"record_cash_payment", "cash", 120, "2027-02-01"}
          ] do
        UpgradeRepo.insert!(%GroupStay.Operations.Record{
          operation_id: id,
          type: type,
          submission: %{
            "type" => type,
            "group_id" => "mixed",
            "amount_cents" => amount,
            "occurred_on" => on
          },
          result: %{
            "status" => "applied",
            "group_id" => "mixed",
            "amount_cents" => amount,
            "revision" => 5
          }
        })
      end

    # An already converted reservation also contains a senior legacy payment.
    UpgradeRepo.insert!(%GroupStay.Reservations.Group{
      group_id: "converted",
      guest_id: "guest",
      property_id: "hotel",
      booked_on: ~D[2027-01-01],
      arrival_on: ~D[2027-06-01],
      departure_on: ~D[2027-06-02],
      rate_plan: "flexible",
      policy_version: "flex-30",
      rooms: rooms,
      lodging_total_cents: 1500,
      deposit_due_cents: 0,
      deposit_paid_cents: 10,
      cash_converted_to_credit_cents: 10,
      status: "cancelled",
      revision: 3
    })

    Ecto.Adapters.SQL.query!(
      UpgradeRepo,
      "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (3, 'guest', 'converted-cancel', 11, '2028-01-01')",
      []
    )

    history =
      for {id, type, amount} <- [
            {"converted-pay", "record_cash_payment", 5},
            {"converted-cancel", "cancel_group", 0}
          ] do
        UpgradeRepo.insert!(%GroupStay.Operations.Record{
          operation_id: id,
          type: type,
          submission: %{"type" => type},
          result: %{"status" => "applied", "group_id" => "converted", "amount_cents" => amount}
        })
      end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    upgraded = UpgradeRepo.get!(GroupStay.Reservations.Group, "mixed")
    assert upgraded.revision == group.revision
    assert upgraded.deposit_paid_cents == 280
    assert upgraded.credit_paid_cents == 120

    assert Enum.map(upgraded.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {40, 60},
             {40, 60},
             {80, 0}
           ]

    assert UpgradeRepo.all(GroupStay.Operations.Record) == records ++ history
    assert UpgradeRepo.aggregate(GroupStay.Credits.Allocation, :sum, :amount_cents) == 120
    assert UpgradeRepo.aggregate(GroupStay.Credits.Lot, :sum, :remaining_cents) == 41

    previous = GroupStay.Repo.put_dynamic_repo(repo)

    try do
      assert {:ok, %{held_cents: 120, recorded_cents: 120}} = GroupStay.Payments.statement("cash")

      [result] =
        GroupStay.Operations.process_batch([
          %{
            "operation_id" => "reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "cash",
            "occurred_on" => "2027-02-01",
            "amount_cents" => 100
          }
        ])

      assert result["status"] == "applied"
      reduced = GroupStay.Reservations.get_group("mixed")
      assert Enum.map(reduced.rooms, & &1["cash_paid_cents"]) == [40, 20, 0]
      assert GroupStay.Reservations.ledger(~D[2027-02-01]).credit_liability_cents == 161

      assert {:ok, %{converted_to_credit_cents: 5}} =
               GroupStay.Payments.statement("converted-pay")

      [charged] =
        GroupStay.Operations.process_batch([
          %{
            "operation_id" => "charge",
            "type" => "charge_back_payment",
            "payment_operation_id" => "converted-pay",
            "occurred_on" => "2027-02-01"
          }
        ])

      assert charged["charged_back_cents"] == 5
      assert UpgradeRepo.get!(GroupStay.Credits.Lot, 3).remaining_cents == 6
      assert GroupStay.Reservations.ledger(~D[2027-02-01]).credit_liability_cents == 156
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end
end
