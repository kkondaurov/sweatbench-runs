defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures

  alias GroupStay.{Credit, Operations, Repo, Reservations}
  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.Group

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @repo_name GroupStay.PersistenceTestRepo
  @migrations [
    {20_260_907_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_907_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_907_000_002, GroupStay.Repo.Migrations.CreateOperations},
    {20_260_907_000_003, GroupStay.Repo.Migrations.AddRoomAccounting},
    {20_260_907_000_004, GroupStay.Repo.Migrations.AddDepositTransfers},
    {20_260_907_000_005, GroupStay.Repo.Migrations.AddFinanceReporting}
  ]

  setup_all do
    for path <- Path.wildcard("priv/repo/migrations/*.exs"), do: Code.require_file(path)

    :ok
  end

  setup %{tmp_dir: directory} = context do
    # Real, independent connections are needed to exercise SQLite's write locks;
    # sandbox allowances would make all workers share a single transaction.
    options = [
      name: @repo_name,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: context[:busy_timeout] || 5_000
    ]

    # Initialize the database before starting several connections, avoiding
    # contention while SQLite first configures its journal.
    start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous_repo = Repo.put_dynamic_repo(@repo_name)
    on_exit(fn -> Repo.put_dynamic_repo(previous_repo) end)

    migrations =
      cond do
        context[:old_schema] -> Enum.take(@migrations, 1)
        context[:cancellation_schema] -> Enum.take(@migrations, 2)
        context[:durable_schema] -> Enum.take(@migrations, 3)
        context[:room_schema] -> Enum.take(@migrations, 4)
        context[:transfer_schema] -> Enum.take(@migrations, 5)
        true -> @migrations
      end

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    %{repo_options: options}
  end

  @tag busy_timeout: 20
  test "retries a busy BEGIN after the competing writer releases its lock" do
    Reservations.process_batch([open_group()])
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:group_stay, :repo, :query],
      fn
        _, _, %{query: "begin", result: {:error, _}}, recipient ->
          send(recipient, :begin_failed)

        _, _, _, _ ->
          :ok
      end,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(@repo_name)

        Repo.with_write_transaction(fn ->
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked

    payment =
      Task.async(fn ->
        Repo.put_dynamic_repo(@repo_name)
        Reservations.process_batch([operation("record_cash_payment", %{"amount_cents" => 100})])
      end)

    assert_receive :begin_failed, 5_000
    send(writer.pid, :release)
    assert Task.await(writer) == {:ok, :ok}
    assert [%{revision: 2, amount_cents: 100}] = Task.await(payment)
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
  end

  test "an error inside a write transaction rolls back and is never replayed" do
    Reservations.process_batch([open_group()])
    before = Reservations.get_group("group-81")

    assert_raise Exqlite.Error, fn ->
      Repo.with_write_transaction(fn ->
        send(self(), :body_executed)
        before |> Ecto.Changeset.change(deposit_paid_cents: 100) |> Repo.update!()
        raise Exqlite.Error, message: "database is locked", statement: "UPDATE groups"
      end)
    end

    assert_received :body_executed
    refute_received :body_executed
    assert Reservations.get_group("group-81") == before
  end

  @tag :old_schema
  test "upgrades earlier groups using original booking dates without changing balances or revisions" do
    for {id, booked_on, plan, status} <- [
          {"old", "2026-12-31", "flexible", "active"},
          {"new", "2027-01-01", "flexible", "active"},
          {"advance", "2026-12-31", "advance_purchase", "active"},
          {"cancelled", "2027-01-01", "flexible", "cancelled"}
        ] do
      {due, paid, refunded} = if status == "active", do: {19_500, 500, 0}, else: {0, 0, 500}

      Repo.query!(
        """
        INSERT INTO groups
          (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
           rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
           deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2027-03-02', '2027-03-05', ?, ?, 7, ?, 97500, ?, ?, ?, 0)
        """,
        [id, booked_on, plan, status, Jason.encode!(open_group()["rooms"]), due, paid, refunded]
      )
    end

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_001,
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    for {id, policy, deadline} <- [
          {"old", "flex-14", ~D[2027-02-16]},
          {"new", "flex-30", ~D[2027-01-31]},
          {"advance", "advance-nonrefundable", nil},
          {"cancelled", "flex-30", ~D[2027-01-31]}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 7
      assert group.credit_paid_cents == 0
      assert group.cash_converted_to_credit_cents == 0
      assert GroupStayWeb.GroupJSON.data(group).refundable_until == deadline
      assert Enum.map(group.rooms, & &1.room_id) == ["room-b", "room-a"]
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 1_500,
             cash_refunded_cents: 500,
             cash_retained_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{refunded_cents: 500, revision: 8}, %{retained_cents: 500, revision: 8}] =
             Reservations.process_batch(
               for id <- ["old", "new"] do
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => "2027-02-10"})
               end
             )

    before = Repo.all(Group)
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Repo.all(Group) == before
  end

  test "credit lots, allocations and policies survive restart and can still be settled", %{
    repo_options: options
  } do
    issue_credit()

    assert [%{status: "applied"}, %{revision: 2}] =
             Reservations.process_batch([
               open_group(%{"group_id" => "target"}),
               operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60})
             ])

    snapshot = {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation)}
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation)} == snapshot
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 50
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 60

    assert [%{revision: 3, credit_issued_cents: 0}] =
             Reservations.process_batch([operation("cancel_group", %{"group_id" => "target"})])

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
    assert Reservations.ledger(~D[2026-10-04]).cash_converted_to_credit_cents == 100
    assert Repo.aggregate(Allocation, :count) == 0
  end

  @tag :cancellation_schema
  test "durable operations migration preserves prior cash and credit without reconstructing audit records" do
    {:ok, group} = GroupStay.Reservations.Booking.build(open_group(), ~D[2026-10-03])
    Repo.insert!(%{group | revision: 7, deposit_paid_cents: 150, credit_paid_cents: 50})

    Repo.query!("""
    INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on)
    VALUES ('guest-22', 'legacy-cancel', 60, '2027-10-04')
    """)

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES (?, 1, 50)",
      [group.group_id]
    )

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    migrated = Reservations.get_group(group.group_id)
    assert migrated.revision == 7
    assert migrated.deposit_paid_cents == 150
    assert migrated.credit_paid_cents == 50
    assert Repo.one!(Lot).remaining_cents == 60
    assert Repo.one!(Allocation).amount_cents == 50
    assert Reservations.ledger().credit_liability_cents == 110
    assert Repo.aggregate(Operation, :count) == 0
    assert Operations.get_result("legacy-cancel") == nil

    payment = operation("record_cash_payment", %{"amount_cents" => 10, "expected_revision" => 7})
    assert [%{revision: 8}, %{revision: 8}] = Reservations.process_batch([payment, payment])
    assert Reservations.get_group(group.group_id).deposit_paid_cents == 160
    assert Repo.aggregate(Operation, :count) == 1
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
  end

  test "competing groups cannot spend the same guest credit" do
    issue_credit()

    Reservations.process_batch(
      for index <- 1..4, do: open_group(%{"group_id" => "target-#{index}"})
    )

    results =
      race(fn index ->
        operation("apply_hotel_credit", %{"group_id" => "target-#{index}", "amount_cents" => 100})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 3
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 10
    assert Repo.aggregate(Allocation, :sum, :amount_cents) == 100
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 110
  end

  test "credit funding checks competing revisions before consuming any lots" do
    issue_credit()
    Reservations.process_batch([open_group(%{"group_id" => "target"})])

    results =
      race(fn index ->
        operation("apply_hotel_credit", %{
          "operation_id" => "apply-#{index}",
          "group_id" => "target",
          "amount_cents" => 10,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 3
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 100
    assert Reservations.get_group("target").revision == 2
  end

  test "committed groups and settlements survive a repository restart and migration rerun", %{
    repo_options: options
  } do
    Reservations.process_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 500}),
      operation("cancel_group"),
      open_group(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 250})
    ])

    cancelled = Reservations.get_group("group-81")
    active = Reservations.get_group("active")
    totals = Reservations.ledger()

    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []

    assert Reservations.get_group("group-81") == cancelled
    assert Reservations.get_group("active") == active
    assert Reservations.ledger() == totals

    assert totals == %{
             cash_held_cents: 250,
             cash_refunded_cents: 500,
             cash_retained_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "only one competing update can apply against a revision" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 3
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "unconditional competing payments cannot overfund a deposit" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 10_000
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 3
    assert Reservations.ledger().cash_held_cents == 10_000
  end

  test "competing openings preserve group uniqueness" do
    results = race(fn index -> open_group(%{"operation_id" => "open-#{index}"}) end)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 3
    assert Reservations.get_group("group-81").revision == 1
  end

  test "concurrent exact retries commit one payment and return one original result" do
    Reservations.process_batch([open_group()])
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    results = race(fn _ -> payment end)
    assert [%{revision: 2, status: "applied"}] = Enum.uniq(results)
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
    assert Repo.aggregate(Operation, :count) == 2
  end

  test "concurrent different payloads reserve an identifier for just one submission" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{"operation_id" => "shared", "amount_cents" => index})
      end)

    assert [applied] = Enum.filter(results, &(&1.status == "applied"))
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 3
    assert Reservations.get_group("group-81").deposit_paid_cents == applied.amount_cents
    assert Reservations.get_group("group-81").revision == 2

    assert Repo.get_by!(Operation, operation_id: "shared").payload["amount_cents"] ==
             applied.amount_cents
  end

  test "concurrent rejections are remembered once" do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    assert [%{code: "group_not_found"}] = race(fn _ -> payment end) |> Enum.uniq()
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "audit insertion failure rolls back settlement and aborts the batch, allowing an exact retry" do
    Reservations.process_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    earlier = open_group(%{"group_id" => "earlier"})

    cancellation =
      operation("cancel_group", %{"refund_method" => "hotel_credit", "operation_id" => "fault"})

    later = open_group(%{"group_id" => "later"})

    before =
      {Repo.all(Lot), Repo.all(Allocation), Reservations.get_group("group-81"),
       Reservations.ledger()}

    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_raise Exqlite.Error, fn ->
      Reservations.process_batch([earlier, cancellation, later])
    end

    assert {Repo.all(Lot), Repo.all(Allocation), Reservations.get_group("group-81"),
            Reservations.ledger()} == before

    assert Operations.get_result(earlier["operation_id"])["revision"] == 1
    assert Operations.get_result("fault") == nil
    assert Operations.get_result(later["operation_id"]) == nil
    assert Reservations.get_group("later") == nil

    Repo.query!("DROP TRIGGER fail_audit")

    assert [%{revision: 1}, %{revision: 3, credit_issued_cents: 110}, %{revision: 1}] =
             Reservations.process_batch([earlier, cancellation, later])

    assert Repo.one!(Lot).remaining_cents == 110
  end

  test "results and complete audit records survive repository and application process restarts",
       %{repo_options: options} do
    submissions = [
      operation("record_cash_payment", %{"amount_cents" => 100}),
      open_group(%{"extra" => [%{"nested" => true}]}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-03-01"}),
      open_group(%{"group_id" => "cold-destination"}),
      operation("record_cash_payment", %{"operation_id" => "cold-payment", "amount_cents" => 100}),
      deposit_transfer("group-81", "cold-destination", 50),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "cold-payment",
        "amount_cents" => 5
      }),
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
      operation("charge_back_payment", %{"payment_operation_id" => "cold-payment"}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      operation("cancel_group", %{"expected_revision" => %{"arbitrary-partner-key" => [nil, 1.0]}})
    ]

    results = Reservations.process_batch(submissions)
    records = Repo.all(Operation)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Reservations.process_batch(submissions) == results
    assert Repo.all(Operation) == records

    # A separate BEAM starts the complete application against the same database.
    # No process-local state from the submitting application can supply a retry.
    script = """
    submissions = Jason.decode!(File.read!(System.fetch_env!("RETRY_PAYLOAD_PATH")))
    IO.puts("RETRY_RESULTS=" <> Jason.encode!(GroupStay.Reservations.process_batch(submissions)))
    """

    payload_path = Path.join(Path.dirname(options[:database]), "retry.json")
    File.write!(payload_path, Jason.encode!(submissions))

    {output, status} =
      System.cmd("mix", ["run", "-e", script],
        env: [
          {"MIX_ENV", "test"},
          {"GROUP_STAY_DATABASE_PATH", options[:database]},
          {"RETRY_PAYLOAD_PATH", payload_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    result_line =
      output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "RETRY_RESULTS="))

    assert result_line, output

    assert result_line |> String.replace_prefix("RETRY_RESULTS=", "") |> Jason.decode!() ==
             results |> Jason.encode!() |> Jason.decode!()

    assert Repo.all(Operation) == records
    assert Reservations.get_group("group-81").revision == 8
  end

  @tag :durable_schema
  test "room migration puts legacy cash and lot consumption ahead of durable funding commit order" do
    legacy_group("group-81", "active", 400, 300, 140)
    legacy_lot(1, "legacy-a", 30, "2026-12-31")
    legacy_lot(2, "legacy-b", 40, "2027-12-31")

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('group-81', 1, 70), ('group-81', 2, 70)"
    )

    remember_old("credit-first", "apply_hotel_credit", "group-81", 50, "2027-01-01")
    remember_old("cash-middle", "record_cash_payment", "group-81", 120, "2026-10-01")
    remember_old("credit-last", "apply_hotel_credit", "group-81", 30, "2026-10-10")
    records = Repo.all(Operation)
    balances = Repo.query!("SELECT remaining_cents FROM credit_lots ORDER BY id").rows

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    group = Reservations.get_group("group-81")
    assert group.revision == 7

    assert Enum.map(group.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) == [
             {40, 60},
             {50, 50},
             {70, 30},
             {0, 0}
           ]

    assert group.deposit_paid_cents == 300
    assert group.credit_paid_cents == 140
    assert Repo.query!("SELECT remaining_cents FROM credit_lots ORDER BY id").rows == balances
    assert Repo.all(Operation) == records
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 210
    assert {:error, "operation_not_found"} = GroupStay.Payments.statement("legacy-cash")

    assert [%{revision: 8, outstanding_deposit_cents: 180}] =
             Reservations.process_batch([
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => "cash-middle",
                 "amount_cents" => 80,
                 "expected_revision" => 7
               })
             ])

    assert Enum.map(
             Reservations.get_group("group-81").rooms,
             &{&1.cash_paid_cents, &1.credit_paid_cents}
           ) == [{40, 60}, {40, 50}, {0, 30}, {0, 0}]

    assert [%{refunded_cents: 40}] =
             Reservations.process_batch([operation("cancel_rooms", %{"room_ids" => ["r1"]})])

    assert {:ok, %{recorded_cents: 120, held_cents: 40, reduced_cents: 80, refunded_cents: 0}} =
             GroupStay.Payments.statement("cash-middle")

    assert Repo.all(Operation) |> Enum.take(3) == records
  end

  @tag :durable_schema
  test "room migration reconstructs historical payment dispositions and incremental credit entitlements" do
    legacy_group("refunded", "cancelled", 0, 0, 0, 20, 0, 0)
    legacy_group("retained", "cancelled", 0, 0, 0, 0, 30, 0)
    legacy_group("converted", "cancelled", 0, 0, 0, 0, 0, 10)
    legacy_group("target", "active", 400, 6, 6)
    remember_old("refund-pay", "record_cash_payment", "refunded", 15)
    remember_old("retain-pay", "record_cash_payment", "retained", 25)
    remember_old("convert-one", "record_cash_payment", "converted", 1)
    remember_old("convert-two", "record_cash_payment", "converted", 5)
    remember_old("conversion", "cancel_group", "converted", 0)
    legacy_lot(1, "conversion", 5, "2027-10-04")

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('target', 1, 6)"
    )

    before = Repo.all(Operation)

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

    assert {:ok, %{recorded_cents: 15, held_cents: 0, refunded_cents: 15}} =
             GroupStay.Payments.statement("refund-pay")

    assert {:ok, %{recorded_cents: 25, held_cents: 0, retained_cents: 25}} =
             GroupStay.Payments.statement("retain-pay")

    assert Enum.map(
             Repo.all(GroupStay.Credit.Entitlement),
             &{&1.payment_operation_id, &1.amount_cents}
           ) == [{"convert-one", 2}, {"convert-two", 5}]

    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 11

    assert [%{charged_back_cents: 1, revision: 8}, %{charged_back_cents: 5, revision: 9}] =
             Reservations.process_batch([
               operation("charge_back_payment", %{"payment_operation_id" => "convert-one"}),
               operation("charge_back_payment", %{"payment_operation_id" => "convert-two"})
             ])

    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 2
    assert Reservations.get_group("target").revision == 7
    assert Reservations.ledger(~D[2026-10-04]).cash_converted_to_credit_cents == 4
    Reservations.process_batch([operation("cancel_group", %{"group_id" => "target"})])
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 4
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 0
    assert Repo.all(Operation) |> Enum.take(5) == before
  end

  test "concurrent reductions cannot overdraw one payment and chargeback retries apply once" do
    Reservations.process_batch([
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100})
    ])

    results =
      race(fn _ ->
        operation("reduce_cash_payment", %{
          "payment_operation_id" => "payment",
          "amount_cents" => 40
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "reduction_exceeds_held_cash")) == 2

    chargeback =
      operation("charge_back_payment", %{
        "payment_operation_id" => "payment",
        "expected_revision" => 4
      })

    assert [%{charged_back_cents: 20, revision: 5}] = race(fn _ -> chargeback end) |> Enum.uniq()

    assert {:ok, %{held_cents: 0, reduced_cents: 80, charged_back_cents: 20}} =
             GroupStay.Payments.statement("payment")

    assert Reservations.ledger().cash_charged_back_cents == 20
  end

  test "room settlements, corrections and shortfalls survive restart with exact retries", %{
    repo_options: options
  } do
    submissions = [
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 10_000}),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 500
      }),
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 9_000}),
      operation("charge_back_payment", %{"payment_operation_id" => "payment"})
    ]

    results = Reservations.process_batch(submissions)
    assert Enum.all?(results, &(&1.status == "applied"))
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 9_000

    before =
      {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation), Repo.all(Operation),
       Repo.all(GroupStay.Reservations.RoomFunding), Repo.all(GroupStay.Payments.Payment),
       Repo.all(GroupStay.Credit.Entitlement)}

    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.process_batch(submissions) == results

    assert {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation), Repo.all(Operation),
            Repo.all(GroupStay.Reservations.RoomFunding), Repo.all(GroupStay.Payments.Payment),
            Repo.all(GroupStay.Credit.Entitlement)} == before

    assert {:ok,
            %{
              recorded_cents: 10_000,
              held_cents: 0,
              reduced_cents: 500,
              charged_back_cents: 9_500
            }} = GroupStay.Payments.statement("payment")

    Reservations.process_batch([operation("cancel_group", %{"group_id" => "target"})])
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 0
  end

  @tag :room_schema
  test "transfer migration preserves earlier statements and backfills settlement attribution" do
    Reservations.process_batch([open_group(), open_group(%{"group_id" => "destination"})])
    remember_old("old-payment", "record_cash_payment", "group-81", 150)

    Repo.query!("""
    INSERT INTO cash_payments
      (payment_operation_id, original_group_id, recorded_cents, refunded_cents,
       retained_cents, converted_to_credit_cents)
    VALUES ('old-payment', 'group-81', 150, 30, 20, 50)
    """)

    group = Reservations.get_group("group-81")
    GroupStay.Reservations.RoomAccounting.fund(group, 50, %{payment_operation_id: "old-payment"})
    changes = GroupStay.Reservations.RoomAccounting.changes(group)

    group
    |> Ecto.Changeset.change(
      Map.merge(changes, %{
        cash_refunded_cents: 30,
        cash_retained_cents: 20,
        cash_converted_to_credit_cents: 50
      })
    )
    |> Repo.update!()

    legacy_lot(1, "old-conversion", 55, "2027-10-04")

    Repo.query!(
      "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents) VALUES (1, 'old-payment', 55)"
    )

    before = {Repo.all(Group), Repo.all(Operation), Repo.all(Lot)}

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_004,
             20_260_907_000_005
           ]

    assert {Repo.all(Group), Repo.all(Operation), Repo.all(Lot)} == before
    assert {:ok, statement} = GroupStay.Payments.statement("old-payment")
    refute Map.has_key?(statement, :held_by_group)

    assert %{
             held_cents: 50,
             refunded_cents: 30,
             retained_cents: 20,
             converted_to_credit_cents: 50
           } = statement

    assert [%{status: "applied"}, %{charged_back_cents: 150, revision: 3}] =
             Reservations.process_batch([
               deposit_transfer("group-81", "destination", 25),
               operation("charge_back_payment", %{"payment_operation_id" => "old-payment"})
             ])

    assert Reservations.get_group("destination").revision == 3

    assert %{
             cash_held_cents: 0,
             cash_refunded_cents: 0,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_charged_back_cents: 150,
             credit_liability_cents: 0
           } = Reservations.ledger(~D[2026-10-04])

    assert {:ok, %{held_by_group: []}} = GroupStay.Payments.statement("old-payment")
  end

  @tag :cancellation_schema
  test "legacy cash and credit can transfer without acquiring a payment identity" do
    legacy_group("group-81", "active", 400, 150, 50)
    legacy_lot(1, "legacy-credit", 60, "2027-10-04")

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('group-81', 1, 50)"
    )

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    Reservations.process_batch([open_group(%{"group_id" => "destination"})])
    before = Reservations.ledger(~D[2026-10-04])

    assert [%{source_revision: 8, destination_revision: 2}] =
             Reservations.process_batch([
               deposit_transfer("group-81", "destination", 120)
             ])

    assert Reservations.ledger(~D[2026-10-04]) == before
    assert Reservations.get_group("group-81").deposit_paid_cents == 30
    assert Reservations.get_group("destination").credit_paid_cents == 50
    assert Repo.all(GroupStay.Payments.Payment) == []

    assert [%{refunded_cents: 70, credit_issued_cents: 0}] =
             Reservations.process_batch([
               operation("cancel_group", %{"group_id" => "destination"})
             ])

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
  end

  test "concurrent transfer retries commit one move and conflicting payloads preserve it" do
    Reservations.process_batch([
      open_group(),
      open_group(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100})
    ])

    transfer = deposit_transfer("group-81", "destination", 60)
    results = race(fn _ -> transfer end)
    assert Enum.uniq(results) |> length() == 1
    assert hd(results).status == "applied"
    assert Reservations.get_group("group-81").revision == 3
    assert Reservations.get_group("destination").revision == 2
    assert Reservations.get_group("destination").deposit_paid_cents == 60

    assert [%{code: "operation_id_conflict"}] =
             Reservations.process_batch([Map.put(transfer, "amount_cents", 40)])
  end

  test "competing transfers cannot overdraw a source or overfill a destination" do
    Reservations.process_batch([
      open_group(),
      open_group(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results = race(fn _ -> deposit_transfer("group-81", "destination", 60) end)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_held_funding")) == 3

    Reservations.process_batch([
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("record_cash_payment", %{"group_id" => "destination", "amount_cents" => 19_400})
    ])

    results = race(fn _ -> deposit_transfer("group-81", "destination", 30) end)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_outstanding")) == 3
    assert Reservations.get_group("destination").deposit_paid_cents == 19_490
  end

  test "competing transfers check destination revisions after seeing prior commits" do
    Reservations.process_batch([
      open_group(),
      open_group(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results =
      race(fn _ ->
        deposit_transfer("group-81", "destination", 10, %{"destination_expected_revision" => 1})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert Enum.count(
             results,
             &(Map.get(&1, :code) == "stale_revision" and &1.group_id == "destination")
           ) == 3

    assert Reservations.get_group("group-81").deposit_paid_cents == 90
  end

  test "transfer provenance, statement history and cross-group corrections survive restart", %{
    repo_options: options
  } do
    submissions = [
      open_group(),
      open_group(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      deposit_transfer("group-81", "destination", 60),
      operation("cancel_group", %{"group_id" => "destination", "refund_method" => "hotel_credit"})
    ]

    results = Reservations.process_batch(submissions)
    assert Enum.all?(results, &(&1.status == "applied"))
    {:ok, statement} = GroupStay.Payments.statement("payment")
    before = Reservations.ledger(~D[2026-10-04])
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Reservations.process_batch(submissions) == results
    assert GroupStay.Payments.statement("payment") == {:ok, statement}
    assert Reservations.ledger(~D[2026-10-04]) == before

    assert [%{charged_back_cents: 100, revision: 4}] =
             Reservations.process_batch([
               operation("charge_back_payment", %{"payment_operation_id" => "payment"})
             ])

    assert Reservations.get_group("destination").revision == 4

    assert {:ok, %{held_by_group: [], charged_back_cents: 100}} =
             GroupStay.Payments.statement("payment")

    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 0
  end

  @tag :transfer_schema
  test "finance migration preserves legacy funding and inception survives restart", %{
    repo_options: options
  } do
    Reservations.process_batch([open_group()])
    group = Reservations.get_group("group-81")
    GroupStay.Reservations.RoomAccounting.fund(group, 100, %{})
    legacy_lot(1, "legacy-credit", 110, "2027-10-04")
    {:ok, [{1, 50}]} = Credit.apply_to_group(group, 50, ~D[2026-10-04])
    GroupStay.Reservations.RoomAccounting.fund(group, 50, %{credit_lot_id: 1})
    GroupStay.Reservations.RoomAccounting.refresh_groups([group.group_id])
    before = {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation), Repo.all(Operation)}

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_005
           ]

    assert {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation), Repo.all(Operation)} == before
    assert {:error, "report_not_available"} = GroupStay.Finance.daily_report("2026-10-04")

    inception = operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    payment = operation("record_cash_payment", %{"amount_cents" => 25})
    results = Reservations.process_batch([inception, payment])
    assert Enum.all?(results, &(&1.status == "applied"))
    {:ok, report} = GroupStay.Finance.daily_report("2026-10-04")
    assert [%{opening_held_cents: 100, closing_held_cents: 125}] = report.cash
    assert report.credit.opening_liability_cents == 110
    entries = Repo.all(GroupStay.Finance.Entry)

    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Reservations.process_batch([inception, payment]) == results
    assert GroupStay.Finance.daily_report("2026-10-04") == {:ok, report}
    assert Repo.all(GroupStay.Finance.Entry) == entries
    {:ok, expiry} = GroupStay.Finance.daily_report("2027-10-05")
    assert expiry.credit.movements["expired_cents"] == 60
    assert expiry.credit.closing_liability_cents == 50
  end

  test "competing inception operations capture one opening and payment retries post once" do
    Reservations.process_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results =
      race(fn _ -> operation("start_finance_reporting", %{"starts_on" => "2026-10-04"}) end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 3
    payment = operation("record_cash_payment", %{"amount_cents" => 25})
    assert race(fn _ -> payment end) |> Enum.uniq() |> length() == 1
    {:ok, report} = GroupStay.Finance.daily_report("2026-10-04")

    assert [
             %{
               opening_held_cents: 100,
               closing_held_cents: 125,
               movements: %{"received_cents" => 25}
             }
           ] = report.cash
  end

  test "a journal failure rolls back the operation and leaves earlier batch postings committed" do
    Reservations.process_batch([
      open_group(),
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    ])

    Repo.query!("""
    CREATE TRIGGER reject_finance_entry BEFORE INSERT ON finance_entries
    WHEN NEW.amount_cents = 17
    BEGIN SELECT RAISE(ABORT, 'finance write failed'); END
    """)

    first = operation("record_cash_payment", %{"amount_cents" => 10})
    failed = operation("record_cash_payment", %{"amount_cents" => 17})
    later = operation("record_cash_payment", %{"amount_cents" => 20})
    assert_raise Exqlite.Error, fn -> Reservations.process_batch([first, failed, later]) end
    assert Reservations.get_group("group-81").deposit_paid_cents == 10
    assert Operations.get_result(failed["operation_id"]) == nil
    assert Operations.get_result(later["operation_id"]) == nil
    {:ok, report} = GroupStay.Finance.daily_report("2026-10-04")
    assert [%{closing_held_cents: 10, movements: %{"received_cents" => 10}}] = report.cash
    Repo.query!("DROP TRIGGER reject_finance_entry")

    assert Enum.all?(
             Reservations.process_batch([first, failed, later]),
             &(&1.status == "applied")
           )

    {:ok, report} = GroupStay.Finance.daily_report("2026-10-04")
    assert [%{closing_held_cents: 47, movements: %{"received_cents" => 47}}] = report.cash
  end

  defp deposit_transfer(source, destination, amount, extra \\ %{}) do
    operation(
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        extra
      )
    )
    |> Map.delete("group_id")
  end

  defp legacy_group(id, status, due, paid, credit, refunded \\ 0, retained \\ 0, converted \\ 0) do
    rooms = for n <- 1..4, do: %{"room_id" => "r#{n}", "nightly_rate_cents" => 500}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents)
      VALUES (?, 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-11',
        'flexible', 'flex-14', ?, 7, ?, 2000, ?, ?, ?, ?, ?, ?)
      """,
      [id, status, Jason.encode!(rooms), due, paid, credit, refunded, retained, converted]
    )
  end

  defp legacy_lot(id, source, remaining, expires) do
    Repo.query!(
      "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest-22', ?, ?, ?)",
      [id, source, remaining, expires]
    )
  end

  defp remember_old(id, type, group_id, amount, occurred_on \\ "2026-10-04") do
    payload = %{
      "operation_id" => id,
      "type" => type,
      "group_id" => group_id,
      "amount_cents" => amount,
      "occurred_on" => occurred_on
    }

    result = %{
      "operation_id" => id,
      "status" => "applied",
      "group_id" => group_id,
      "amount_cents" => amount,
      "revision" => 7
    }

    Repo.insert!(%Operation{operation_id: id, type: type, payload: payload, result: result})
  end

  defp issue_credit do
    results =
      Reservations.process_batch([
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group", %{"refund_method" => "hotel_credit"})
      ])

    assert Enum.all?(results, &(&1.status == "applied"))
  end

  defp race(build_operation) do
    parent = self()

    tasks =
      for index <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(@repo_name)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.process_batch([build_operation.(index)]) |> hd()
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    # Four BEGIN attempts can each consume the configured five-second busy
    # timeout. Allow that retry budget before treating a competing task as hung.
    Task.await_many(tasks, 30_000)
  end
end
