defmodule GroupStay.PersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures
  import Ecto.Query
  alias GroupStay.{Operation, Repo}

  @moduletag :tmp_dir
  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_002, GroupStay.Repo.Migrations.CreateOperations},
    {20_260_905_000_003, GroupStay.Repo.Migrations.AddRoomAccounting}
  ]

  setup_all do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateGroups) do
      Code.require_file("priv/repo/migrations/20260905000000_create_groups.exs")
    end

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddCancellationEconomics) do
      Code.require_file("priv/repo/migrations/20260905000001_add_cancellation_economics.exs")
    end

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateOperations) do
      Code.require_file("priv/repo/migrations/20260905000002_create_operations.exs")
    end

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddRoomAccounting) do
      Code.require_file("priv/repo/migrations/20260905000003_add_room_accounting.exs")
    end

    :ok
  end

  setup %{tmp_dir: directory} do
    options = [
      name: __MODULE__,
      database: Path.join(directory, "group_stay.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 10_000
    ]

    # Initialize the database before starting concurrent WAL connections.
    start_repo(Keyword.put(options, :pool_size, 1))
    Repo.put_dynamic_repo(__MODULE__)
    migrate(:up)
    stop_supervised!(__MODULE__)
    start_repo(options)
    %{repo_options: options}
  end

  test "committed batches, ordered rooms and settlements survive a repository restart", context do
    assert [
             %{status: "applied", revision: 1},
             %{status: "applied", revision: 2},
             %{status: "rejected", code: "payment_exceeds_outstanding"},
             %{status: "applied", revision: 3}
           ] =
             GroupStay.submit_operations([
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 5000}),
               operation("record_cash_payment", %{"amount_cents" => 20000}),
               operation("cancel_group")
             ])

    before_group = GroupStay.get_group("group-81")
    before_ledger = GroupStay.ledger()
    stop_supervised!(__MODULE__)
    start_repo(context.repo_options)

    assert migrate(:up) == []
    assert GroupStay.get_group("group-81") == before_group
    assert GroupStay.ledger() == before_ledger
    assert before_ledger.cash_refunded_cents == 5000
    assert before_group.revision == 3

    assert [%{status: "rejected", code: "group_not_active"}] =
             GroupStay.submit_operations([operation("cancel_group")])
  end

  test "concurrent conditional payments apply once and return the committed revision to losers" do
    GroupStay.submit_operations([open_operation()])

    results =
      concurrently(12, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 11

    assert Enum.all?(rejected, fn result ->
             result.code == "stale_revision" and result.actual_revision == 2 and
               result.expected_revision == 1
           end)

    assert GroupStay.get_group("group-81").revision == 2
    assert GroupStay.ledger().cash_held_cents == 100
  end

  test "concurrent unconditional payments never lose cash or revision increments" do
    GroupStay.submit_operations([open_operation()])

    results =
      concurrently(12, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..13)
    assert GroupStay.get_group("group-81").deposit_paid_cents == 1200
    assert GroupStay.ledger().cash_held_cents == 1200
  end

  test "concurrent openings enforce unique group IDs without aborting either request" do
    results = concurrently(8, &open_operation(%{"operation_id" => "open-#{&1}"}))

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert Enum.count(results, fn result ->
             result.status == "rejected" and result.code == "group_already_exists"
           end) == 7

    assert GroupStay.get_group("group-81").revision == 1
    assert length(GroupStay.get_group("group-81").rooms) == 2
  end

  test "the migrations can be rolled back and reapplied" do
    assert [_rooms, _operations, _economics, _core] = migrate(:down)
    assert [_core, _economics, _operations, _rooms] = migrate(:up)
    assert [%{status: "applied"}] = GroupStay.submit_operations([open_operation()])
  end

  test "upgrading the original schema backfills policies without changing bookings or cash" do
    Ecto.Migrator.run(Repo, @migrations, :down, step: 3, log: false)

    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 5000, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 1000, 0, 0},
          {"advance", "2027-01-01", "advance_purchase", "active", 2000, 0, 0},
          {"cancelled", "2026-10-03", "flexible", "cancelled", 0, 3000, 0},
          {"retained", "2026-10-03", "advance_purchase", "cancelled", 0, 0, 4000}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
          cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'legacy-guest', 'ams-canal', ?, '2028-03-01', '2028-03-04', ?, ?, 7, 97500, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          if(status == "active",
            do: if(plan == "advance_purchase", do: 97500, else: 19500),
            else: 0
          ),
          paid,
          refunded,
          retained
        ]
      )

      for {room, position, rate} <- [{"room-b", 0, 15000}, {"room-a", 1, 17500}] do
        Repo.query!(
          "INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents) VALUES (?, ?, ?, ?)",
          [id, room, position, rate]
        )
      end
    end

    before_groups = Repo.query!("SELECT * FROM groups ORDER BY group_id")
    before_rooms = Repo.query!("SELECT * FROM rooms ORDER BY id")

    assert [20_260_905_000_001, 20_260_905_000_002] =
             Ecto.Migrator.run(Repo, Enum.take(@migrations, 3), :up, all: true, log: false)

    assert Repo.query!(
             "SELECT #{Enum.join(before_groups.columns, ", ")} FROM groups ORDER BY group_id"
           ).rows == before_groups.rows

    assert Repo.query!("SELECT * FROM rooms ORDER BY id").rows == before_rooms.rows

    assert [20_260_905_000_003] = migrate(:up)
    assert migrate(:up) == []

    for {id, policy, deadline, cash} <- [
          {"old", "flex-14", ~D[2028-02-16], 5000},
          {"new", "flex-30", ~D[2028-01-31], 1000},
          {"advance", "advance-nonrefundable", nil, 2000},
          {"cancelled", "flex-14", ~D[2028-02-16], 0},
          {"retained", "advance-nonrefundable", nil, 0}
        ] do
      group = GroupStay.get_group(id)
      assert group.policy_version == policy
      assert group.refundable_until == deadline
      assert group.cash_paid_cents == cash
      assert group.credit_paid_cents == 0
      assert group.revision == 7
      assert Enum.map(group.rooms, & &1.room_id) == ["room-b", "room-a"]
    end

    assert GroupStay.ledger() == %{
             cash_held_cents: 8000,
             cash_refunded_cents: 3000,
             cash_retained_cents: 4000,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }

    assert [
             %{revision: 8, policy_version: "flex-14", refundable_until: ~D[2028-04-17]},
             %{revision: 9, credit_issued_cents: 5500}
           ] =
             GroupStay.submit_operations([
               operation("reschedule_group", %{
                 "group_id" => "old",
                 "new_arrival_on" => "2028-05-01",
                 "expected_revision" => 7
               }),
               operation("cancel_group", %{
                 "group_id" => "old",
                 "occurred_on" => "2028-04-17",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 8
               })
             ])
  end

  test "credit lots, fixed policies and repeated allocations survive restarts and restore correctly",
       context do
    GroupStay.submit_operations(
      credit_source_operations() ++
        [
          open_operation(%{
            "group_id" => "target",
            "arrival_on" => "2028-12-10",
            "departure_on" => "2028-12-13"
          }),
          operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 1000}),
          operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 1000})
        ]
    )

    before =
      {GroupStay.get_group("target"), GroupStay.ledger(~D[2027-11-26]),
       GroupStay.guest_credit("guest-22", ~D[2027-11-26])}

    stop_supervised!(__MODULE__)
    start_repo(context.repo_options)
    assert migrate(:up) == []

    assert {GroupStay.get_group("target"), GroupStay.ledger(~D[2027-11-26]),
            GroupStay.guest_credit("guest-22", ~D[2027-11-26])} == before

    assert GroupStay.get_group("target").credit_paid_cents == 2000
    assert GroupStay.ledger(~D[2027-11-27]).credit_liability_cents == 2000

    assert [%{revision: 4, credit_issued_cents: 0, refunded_cents: 0}] =
             GroupStay.submit_operations([
               operation("cancel_group", %{
                 "group_id" => "target",
                 "occurred_on" => "2027-11-26",
                 "expected_revision" => 3
               })
             ])

    assert GroupStay.guest_credit("guest-22", ~D[2027-11-26]).available_cents == 5500
    assert GroupStay.ledger(~D[2027-11-27]).credit_liability_cents == 0
  end

  test "concurrent credit redemption across groups never spends the same credit twice" do
    GroupStay.submit_operations(
      credit_source_operations() ++
        for(index <- 1..12, do: open_operation(%{"group_id" => "target-#{index}"}))
    )

    results =
      concurrently(12, fn index ->
        operation("apply_hotel_credit", %{
          "operation_id" => "credit-#{index}",
          "group_id" => "target-#{index}",
          "amount_cents" => 1000,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied" and &1.revision == 2)) == 5

    assert Enum.count(results, &(&1.status == "rejected" and &1.code == "insufficient_credit")) ==
             7

    assert GroupStay.guest_credit("guest-22", ~D[2027-11-26]).available_cents == 500
    assert GroupStay.ledger(~D[2027-11-26]).credit_liability_cents == 5500
    assert GroupStay.ledger().cash_held_cents == 0
  end

  test "concurrent conditional credit applications increment the revision only once" do
    GroupStay.submit_operations(
      credit_source_operations() ++ [open_operation(%{"group_id" => "target"})]
    )

    results =
      concurrently(8, fn index ->
        operation("apply_hotel_credit", %{
          "operation_id" => "credit-#{index}",
          "group_id" => "target",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied" and &1.revision == 2)) == 1

    assert Enum.count(
             results,
             &(&1.status == "rejected" and &1.code == "stale_revision" and &1.actual_revision == 2)
           ) == 7

    assert GroupStay.get_group("target").credit_paid_cents == 100
    assert GroupStay.guest_credit("guest-22", ~D[2027-11-26]).available_cents == 5400
  end

  test "stored submissions, applied results and rejections survive database process restarts",
       context do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 5000, "expected_revision" => 1}),
      operation("cancel_group", %{"expected_revision" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    results = GroupStay.submit_operations(operations)
    records = Repo.all(from op in Operation, order_by: op.id)
    group = GroupStay.get_group("group-81")
    ledger = GroupStay.ledger(~D[2026-11-26])

    stop_supervised!(__MODULE__)
    start_repo(context.repo_options)
    assert migrate(:up) == []
    assert GroupStay.submit_operations(operations) === results
    assert Repo.all(from op in Operation, order_by: op.id) == records
    assert GroupStay.get_group("group-81") == group
    assert GroupStay.ledger(~D[2026-11-26]) == ledger

    for {op, result} <- Enum.zip(operations, results) do
      assert GroupStay.get_operation(op["operation_id"]) ==
               result |> Jason.encode!() |> Jason.decode!()
    end
  end

  test "concurrent retries apply one unconditional payment and remember one original result" do
    GroupStay.submit_operations([open_operation()])
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    results = concurrently(12, fn _ -> payment end)

    assert [%{status: "applied", revision: 2, amount_cents: 100}] = Enum.uniq(results)
    assert GroupStay.get_group("group-81").revision == 2
    assert GroupStay.ledger().cash_held_cents == 100
    assert Repo.aggregate(Operation, :count) == 2
  end

  test "concurrent credit-issuing cancellations create a single lot and settlement" do
    GroupStay.submit_operations([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    results = concurrently(12, fn _ -> cancellation end)

    assert [%{status: "applied", revision: 3, credit_issued_cents: 110}] = Enum.uniq(results)
    assert Repo.aggregate(GroupStay.CreditLot, :count) == 1
    assert GroupStay.ledger(~D[2026-11-26]).cash_converted_to_credit_cents == 100
    assert GroupStay.guest_credit("guest-22", ~D[2026-11-26]).available_cents == 110
  end

  test "concurrent rejections retain a single result even when subsequent state makes it valid" do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    results = concurrently(12, fn _ -> payment end)
    assert [original] = Enum.uniq(results)
    assert original.code == "group_not_found"
    assert Repo.aggregate(Operation, :count) == 1

    GroupStay.submit_operations([open_operation()])
    assert GroupStay.submit_operations([payment]) == [original]
    assert GroupStay.ledger().cash_held_cents == 0
  end

  test "concurrent different payloads under one identifier never replace the winner" do
    results =
      concurrently(12, fn index ->
        open_operation(%{"operation_id" => "shared", "group_id" => "group-#{index}"})
      end)

    assert [winner] = Enum.filter(results, &(&1.status == "applied"))
    assert Enum.count(results, &(&1[:code] == "operation_id_conflict")) == 11
    assert Repo.aggregate(GroupStay.Group, :count) == 1
    assert Repo.aggregate(Operation, :count) == 1
    record = Repo.get_by!(Operation, operation_id: "shared")
    assert record.payload["group_id"] == winner.group_id
    assert GroupStay.submit_operations([record.payload]) == [winner]
  end

  test "audit sequence follows actual commit order under concurrent writes" do
    GroupStay.submit_operations([open_operation()])

    concurrently(12, fn index ->
      operation("record_cash_payment", %{
        "operation_id" => "payment-#{13 - index}",
        "amount_cents" => 100
      })
    end)

    records = Repo.all(from op in Operation, order_by: op.id)
    assert Enum.map(records, & &1.result["revision"]) == Enum.to_list(1..13)
  end

  test "upgrading cancellation economics adds an empty journal without rewriting domain records" do
    GroupStay.submit_operations(credit_source_operations())
    Ecto.Migrator.run(Repo, @migrations, :down, step: 2, log: false)
    tables = ~w(groups rooms credit_lots credit_allocations)
    before = Enum.map(tables, &Repo.query!("SELECT * FROM #{&1}").rows)

    assert [20_260_905_000_002] =
             Ecto.Migrator.run(Repo, Enum.take(@migrations, 3), :up, all: true, log: false)

    assert Enum.map(tables, &Repo.query!("SELECT * FROM #{&1}").rows) == before
    assert Repo.aggregate(Operation, :count) == 0
    assert [20_260_905_000_003] = migrate(:up)

    assert [%{status: "rejected", code: "group_not_active"}] =
             GroupStay.submit_operations([operation("cancel_group")])

    assert Repo.aggregate(Operation, :count) == 1
  end

  test "concurrent reductions never remove more than the target's held cash" do
    GroupStay.submit_operations([
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100})
    ])

    results =
      concurrently(8, fn _ ->
        operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 30})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 3
    assert Enum.count(results, &(&1[:code] == "reduction_exceeds_held_cash")) == 5

    assert {:ok, %{recorded_cents: 100, held_cents: 10, reduced_cents: 90}} =
             GroupStay.get_payment("pay")

    assert GroupStay.get_group("group-81").revision == 5
  end

  test "concurrent chargebacks of one payment commit one reversal and one revision" do
    GroupStay.submit_operations([
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100})
    ])

    results =
      concurrently(8, fn _ ->
        operation("charge_back_payment", %{"payment_operation_id" => "pay"})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "payment_not_chargeable")) == 7
    assert {:ok, %{held_cents: 0, charged_back_cents: 100}} = GroupStay.get_payment("pay")
    assert GroupStay.get_group("group-81").revision == 3
    assert GroupStay.ledger().cash_charged_back_cents == 100
  end

  test "concurrent cancellation retries settle selected rooms exactly once" do
    GroupStay.submit_operations([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 15000})
    ])

    cancel =
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"})

    results = concurrently(8, fn _ -> cancel end)

    assert [%{revision: 3, credit_issued_cents: 9900, cancelled_room_ids: ["room-b"]}] =
             Enum.uniq(results)

    assert GroupStay.get_group("group-81").cash_paid_cents == 6000
    assert GroupStay.ledger(~D[2026-11-26]).cash_converted_to_credit_cents == 9000
    assert Repo.aggregate(GroupStay.CreditLot, :count) == 1
  end

  defp credit_source_operations do
    [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 5000}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]
  end

  defp start_repo(options) do
    start_supervised!(Supervisor.child_spec({Repo, options}, id: __MODULE__))
  end

  defp migrate(direction) do
    Ecto.Migrator.run(Repo, @migrations, direction, all: true, log: false)
  end

  defp concurrently(count, operation_builder) do
    parent = self()

    tasks =
      for index <- 1..count do
        Task.async(fn ->
          Repo.put_dynamic_repo(__MODULE__)
          send(parent, {:ready, self()})

          receive do
            :go ->
              [result] = GroupStay.submit_operations([operation_builder.(index)])
              result
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end
end
