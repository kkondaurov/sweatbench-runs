defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "original databases upgrade with booking policies and cash accounting intact" do
    path = Path.expand("tmp/upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan, status} <- [
          {"old", "2026-12-31", "flexible", "active"},
          {"new", "2027-01-01", "flexible", "active"},
          {"advance", "2026-12-31", "advance_purchase", "cancelled"}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-06-01', '2028-06-02', ?, ?, 7, '[{"room_id":"room","nightly_rate_cents":1000}]', 1000, 200, 100, 0, 0)
        """,
        [id, booked, plan, status]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      for {id, policy, cutoff} <- [
            {"old", "flex-14", ~D[2028-05-18]},
            {"new", "flex-30", ~D[2028-05-02]},
            {"advance", "advance-nonrefundable", nil}
          ] do
        group = GroupStay.Reservations.get_group(id)
        assert group.policy_version == policy
        assert group.refundable_until == cutoff
        assert group.cash_paid_cents == if(id == "advance", do: 0, else: 100)
        assert group.credit_paid_cents == 0
        assert group.deposit_paid_cents == if(id == "advance", do: 0, else: 100)
        assert group.revision == 7
      end

      assert GroupStay.Reservations.ledger().cash_held_cents == 200
      assert GroupStay.Reservations.ledger().credit_liability_cents == 0
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end

  test "durable operations migration preserves existing credit funding without reconstructing records" do
    path = Path.expand("tmp/credit-upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_001, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      group =
        UpgradeRepo.insert!(%GroupStay.Group{
          group_id: "existing",
          guest_id: "guest",
          property_id: "hotel",
          booked_on: ~D[2026-12-31],
          arrival_on: ~D[2027-06-01],
          departure_on: ~D[2027-06-02],
          rate_plan: "flexible",
          policy_version: "flex-14",
          revision: 4,
          rooms: [%{"room_id" => "a", "nightly_rate_cents" => 1000}],
          lodging_total_cents: 1000,
          deposit_due_cents: 200,
          deposit_paid_cents: 75,
          cash_paid_cents: 25,
          credit_paid_cents: 50
        })

      lot =
        UpgradeRepo.insert!(%GroupStay.CreditLot{
          guest_id: "guest",
          source_operation_id: "earlier-cancel",
          remaining_cents: 60,
          expires_on: ~D[2028-01-01]
        })

      allocation =
        UpgradeRepo.insert!(%GroupStay.CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: 50
        })

      Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
      assert UpgradeRepo.get!(GroupStay.Group, group.group_id) == group
      assert UpgradeRepo.get!(GroupStay.CreditLot, lot.id) == lot
      assert UpgradeRepo.get!(GroupStay.CreditAllocation, allocation.id) == allocation
      assert UpgradeRepo.all(GroupStay.Operation) == []
      assert GroupStay.Reservations.get_operation("earlier-cancel") == nil

      [result] =
        GroupStay.Reservations.batch([
          %{
            "operation_id" => "new-cancel",
            "type" => "cancel_group",
            "group_id" => "existing",
            "occurred_on" => "2027-01-01"
          }
        ])

      assert result.refunded_cents == 25
      assert result.revision == 5
      assert GroupStay.Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 110
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end

  test "room upgrade places legacy funding first and durable funding in commit order by retained type" do
    path = Path.expand("tmp/room-upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_002, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      group =
        UpgradeRepo.insert!(%GroupStay.Group{
          group_id: "mixed",
          guest_id: "guest",
          property_id: "hotel",
          booked_on: ~D[2026-01-01],
          arrival_on: ~D[2027-06-01],
          departure_on: ~D[2027-06-02],
          rate_plan: "flexible",
          policy_version: "flex-14",
          revision: 9,
          rooms: Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500}),
          lodging_total_cents: 1500,
          deposit_due_cents: 300,
          deposit_paid_cents: 200,
          cash_paid_cents: 90,
          credit_paid_cents: 110
        })

      lots =
        for {source, amount} <- [{"one", 45}, {"two", 65}] do
          lot =
            UpgradeRepo.insert!(%GroupStay.CreditLot{
              guest_id: "guest",
              source_operation_id: source,
              remaining_cents: 15,
              expires_on: ~D[2028-01-01]
            })

          UpgradeRepo.insert!(%GroupStay.CreditAllocation{
            group_id: "mixed",
            credit_lot_id: lot.id,
            amount_cents: amount
          })

          lot
        end

      for {id, type, amount, date} <- [
            {"credit-first", "apply_hotel_credit", 50, "2027-01-01"},
            {"move", "reschedule_group", 99999, "2027-01-01"},
            {"cash-second", "record_cash_payment", 60, "2026-01-01"},
            {"credit-third", "apply_hotel_credit", 40, "2026-01-01"}
          ] do
        UpgradeRepo.insert!(%GroupStay.Operation{
          operation_id: id,
          type: type,
          payload: %{"type" => type, "occurred_on" => date, "amount_cents" => amount},
          result: %{
            "status" => "applied",
            "group_id" => "mixed",
            "amount_cents" => amount,
            "revision" => 8
          }
        })
      end

      before_allocations = UpgradeRepo.all(GroupStay.CreditAllocation)
      before_operations = UpgradeRepo.all(GroupStay.Operation)
      Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
      assert UpgradeRepo.get!(GroupStay.Group, "mixed") == group
      assert UpgradeRepo.all(GroupStay.CreditAllocation) == before_allocations
      assert UpgradeRepo.all(GroupStay.CreditLot) == lots
      assert UpgradeRepo.all(GroupStay.Operation) == before_operations
      rooms = GroupStay.Reservations.get_group("mixed").rooms

      assert Enum.map(rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
               {30, 70},
               {60, 40},
               {0, 0}
             ]

      assert {:ok, %{held_cents: 60, recorded_cents: 60}} =
               GroupStay.Reservations.get_payment("cash-second")

      assert [%{refunded_cents: 30, revision: 10}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "cancel-a",
                   "type" => "cancel_rooms",
                   "group_id" => "mixed",
                   "room_ids" => ["a"],
                   "occurred_on" => "2027-01-01"
                 }
               ])

      assert Enum.map(UpgradeRepo.all(GroupStay.CreditLot), & &1.remaining_cents) == [60, 40]
      assert GroupStay.Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 140

      assert [%{amount_cents: 60}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "reduce",
                   "type" => "reduce_cash_payment",
                   "payment_operation_id" => "cash-second",
                   "amount_cents" => 60,
                   "occurred_on" => "2027-01-01"
                 }
               ])

      assert {:error, "operation_not_found"} = GroupStay.Reservations.get_payment("legacy-cash")
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end

  test "upgrade reconstructs settled payment statements and credit entitlements without rewriting audit results" do
    path = Path.expand("tmp/settled-upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_002, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      UpgradeRepo.insert!(%GroupStay.Group{
        group_id: "settled",
        guest_id: "guest",
        property_id: "hotel",
        booked_on: ~D[2026-01-01],
        arrival_on: ~D[2027-06-01],
        departure_on: ~D[2027-06-02],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "cancelled",
        revision: 4,
        rooms: [%{"room_id" => "a", "nightly_rate_cents" => 500}],
        lodging_total_cents: 500,
        deposit_due_cents: 0,
        deposit_paid_cents: 10,
        cash_paid_cents: 10,
        cash_converted_to_credit_cents: 10
      })

      payment =
        UpgradeRepo.insert!(%GroupStay.Operation{
          operation_id: "payment",
          type: "record_cash_payment",
          payload: %{},
          result: %{
            "status" => "applied",
            "group_id" => "settled",
            "amount_cents" => 5,
            "revision" => 3
          }
        })

      UpgradeRepo.insert!(%GroupStay.Operation{
        operation_id: "cancel",
        type: "cancel_group",
        payload: %{},
        result: %{"status" => "applied", "group_id" => "settled", "revision" => 4}
      })

      UpgradeRepo.insert!(%GroupStay.CreditLot{
        guest_id: "guest",
        source_operation_id: "cancel",
        remaining_cents: 11,
        expires_on: ~D[2028-01-01]
      })

      Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)

      assert {:ok, %{recorded_cents: 5, converted_to_credit_cents: 5, held_cents: 0}} =
               GroupStay.Reservations.get_payment("payment")

      assert GroupStay.Reservations.get_group("settled").deposit_paid_cents == 0

      assert [%{charged_back_cents: 5, revision: 5}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "charge",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => "payment",
                   "occurred_on" => "2027-01-01"
                 }
               ])

      # The senior five cents own six cents of entitlement; this payment owns the other five.
      assert GroupStay.Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 6
      assert UpgradeRepo.get!(GroupStay.Operation, payment.id) == payment
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end

  test "room-accounting databases upgrade and transferred payment order survives restart" do
    path = Path.expand("tmp/transfer-upgrade-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_003, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      for id <- ~w(source destination) do
        group =
          UpgradeRepo.insert!(%GroupStay.Group{
            group_id: id,
            guest_id: "guest",
            property_id: "hotel",
            booked_on: ~D[2026-01-01],
            arrival_on: ~D[2028-06-01],
            departure_on: ~D[2028-06-02],
            rate_plan: "flexible",
            policy_version: "flex-14",
            rooms: Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500}),
            lodging_total_cents: 1500,
            deposit_due_cents: 300,
            cash_paid_cents: if(id == "source", do: 250, else: 0),
            deposit_paid_cents: if(id == "source", do: 250, else: 0)
          })

        data = GroupStay.Accounting.initialize(group, UpgradeRepo)

        data =
          if id == "source",
            do: GroupStay.Accounting.fund(data, 250, "cash", "payment"),
            else: data

        # Persist exactly the previous release's allocation shape, without order keys.
        Ecto.Adapters.SQL.query!(
          UpgradeRepo,
          "UPDATE room_accounts SET data = ? WHERE group_id = ?",
          [Jason.encode!(data), id]
        )
      end

      UpgradeRepo.insert!(%GroupStay.Operation{
        operation_id: "payment",
        type: "record_cash_payment",
        payload: %{},
        result: %{
          "status" => "applied",
          "group_id" => "source",
          "amount_cents" => 250,
          "revision" => 1
        }
      })

      before = GroupStay.Reservations.ledger()
      Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
      assert GroupStay.Reservations.ledger() == before

      move = %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 25,
        "occurred_on" => "2026-01-01"
      }

      [original] = GroupStay.Reservations.batch([move])
      assert original.status == "applied"
      stop_supervised!(UpgradeRepo)
      start_supervised!({UpgradeRepo, database: path, pool_size: 1})
      assert GroupStay.Reservations.batch([move]) == [original]

      assert [%{status: "applied", revision: 3}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "reduce",
                   "type" => "reduce_cash_payment",
                   "payment_operation_id" => "payment",
                   "amount_cents" => 25,
                   "occurred_on" => "2026-01-01"
                 }
               ])

      assert GroupStay.Reservations.get_group("destination").cash_paid_cents == 0
      assert GroupStay.Reservations.get_group("destination").revision == 3
      assert GroupStay.Reservations.get_group("source").cash_paid_cents == 225

      assert {:ok,
              %{held_by_group: [%{group_id: "source", amount_cents: 225}], reduced_cents: 25}} =
               GroupStay.Reservations.get_payment("payment")
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end
end
