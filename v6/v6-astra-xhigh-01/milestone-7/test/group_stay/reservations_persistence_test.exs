defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures
  import Plug.Conn
  import Phoenix.ConnTest
  import Ecto.Query

  alias GroupStay.{FinanceReporting, Operations, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Entry, Inception}
  alias GroupStay.Operations.Operation

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FundingAllocation,
    Group,
    Payment,
    PaymentSettlement,
    Payments,
    Room
  }

  @endpoint GroupStayWeb.Endpoint

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_002, GroupStay.Repo.Migrations.CreateOperations},
    {20_260_905_000_003, GroupStay.Repo.Migrations.AddRoomAccounting},
    {20_260_905_000_004, GroupStay.Repo.Migrations.AddDepositTransfers},
    {20_260_905_000_005, GroupStay.Repo.Migrations.AddFinanceReporting},
    {20_260_905_000_006, GroupStay.Repo.Migrations.AddFinancePeriodClose}
  ]

  @moduletag capture_log: true

  setup_all do
    for {version, module} <- @migrations, not Code.ensure_loaded?(module) do
      [file] = Path.wildcard(Path.expand("../../priv/repo/migrations/#{version}_*.exs", __DIR__))
      Code.require_file(file)
    end

    :ok
  end

  setup tags do
    directory =
      Path.expand("../../tmp/reservations-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "persistent.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5000
    ]

    # Initialize a new SQLite file with one connection before opening a larger pool.
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(repo)
    on_exit(fn -> remove_database_directory(directory) end)

    # Represent a database created before this release and ensure migrations preserve it.
    Repo.query!("CREATE TABLE existing_data (value TEXT NOT NULL)")
    Repo.query!("INSERT INTO existing_data VALUES ('preserve me')")

    cond do
      tags[:legacy_database] ->
        assert migrate(:up, to: 20_260_905_000_000) == [20_260_905_000_000]

      tags[:previous_release_database] ->
        assert migrate(:up, to: 20_260_905_000_001) == [20_260_905_000_000, 20_260_905_000_001]

      true ->
        assert migrate(:up) == [
                 20_260_905_000_000,
                 20_260_905_000_001,
                 20_260_905_000_002,
                 20_260_905_000_003,
                 20_260_905_000_004,
                 20_260_905_000_005,
                 20_260_905_000_006
               ]
    end

    %{repo: repo, options: options}
  end

  test "migrations preserve existing data and deposits survive repository restarts", %{
    options: options
  } do
    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1234}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      open_operation(%{"group_id" => "settled"}),
      operation("record_cash_payment", %{"group_id" => "settled", "amount_cents" => 567}),
      operation("cancel_group", %{"group_id" => "settled"})
    ])

    active = Reservations.get_group("group-81")
    settled = Reservations.get_group("settled")
    ledger = Reservations.ledger()

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert migrate(:up) == []
    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]
    assert Reservations.get_group("group-81") == active
    assert Reservations.get_group("settled") == settled
    assert Reservations.ledger() == ledger

    assert [%{status: "rejected", code: "stale_revision", actual_revision: 3}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"expected_revision" => 1})
             ])

    assert [%{status: "applied", revision: 4, refunded_cents: 1234}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"expected_revision" => 3})
             ])

    assert migrate(:down) == [
             20_260_905_000_006,
             20_260_905_000_005,
             20_260_905_000_004,
             20_260_905_000_003,
             20_260_905_000_002,
             20_260_905_000_001,
             20_260_905_000_000
           ]

    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]

    assert migrate(:up) == [
             20_260_905_000_000,
             20_260_905_000_001,
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert Reservations.get_group("group-81") == nil
  end

  test "independent connections serialize revision checks, balances, and cancellation", %{
    repo: repo,
    options: options
  } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    repos = [repo, second_repo]

    openings = concurrent_operations(repos, List.duplicate(open_operation(), 8))
    assert Enum.count(openings, &(&1.status == "applied")) == 1
    assert Enum.count(openings, &(Map.get(&1, :code) == "group_already_exists")) == 7

    guarded_payment =
      operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1})

    payments = concurrent_operations(repos, List.duplicate(guarded_payment, 8))
    assert Enum.count(payments, &(&1.status == "applied" and &1.revision == 2)) == 1
    assert Enum.count(payments, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group-81").deposit_paid_cents == 500

    remaining_payment = operation("record_cash_payment", %{"amount_cents" => 19000})
    payments = concurrent_operations(repos, List.duplicate(remaining_payment, 8))
    assert Enum.count(payments, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(payments, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 7
    assert Reservations.ledger().cash_held_cents == 19500

    cancellations = concurrent_operations(repos, List.duplicate(operation("cancel_group"), 8))
    assert Enum.count(cancellations, &(&1.status == "applied" and &1.revision == 4)) == 1
    assert Enum.count(cancellations, &(Map.get(&1, :code) == "group_not_active")) == 7

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 19500,
             cash_retained_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag legacy_database: true
  test "upgrading real legacy groups backfills original booking policies and preserves all accounting" do
    for {id, booked, plan, status, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 0, 0},
          {"new", "2027-01-01", "flexible", "active", 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "active", 0, 0},
          {"refunded", "2026-12-31", "flexible", "cancelled", 345, 0},
          {"retained", "2027-01-01", "flexible", "cancelled", 0, 456}
        ] do
      due =
        if status == "active", do: if(plan == "advance_purchase", do: 97500, else: 19500), else: 0

      paid = if status == "active", do: 1234, else: 0

      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
          cash_refunded_cents, cash_retained_cents)
        VALUES (?, ' Guest-Ä ', 'legacy-property', ?, '2028-03-01', '2028-03-04', ?, ?, 3,
          97500, ?, ?, ?, ?)
        """,
        [id, booked, plan, status, due, paid, refunded, retained]
      )

      Repo.query!(
        "INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position) VALUES (?, 'b', 15000, 0), (?, 'a', 17500, 1)",
        [id, id]
      )
    end

    before_groups = Repo.query!("SELECT * FROM groups ORDER BY group_id")
    before_rooms = Repo.query!("SELECT * FROM rooms ORDER BY id").rows

    assert migrate(:up) == [
             20_260_905_000_001,
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert migrate(:up) == []

    after_groups = Repo.query!("SELECT * FROM groups ORDER BY group_id")

    assert Enum.map(after_groups.rows, &Enum.take(&1, length(before_groups.columns))) ==
             Enum.map(before_groups.rows, fn row ->
               if Enum.at(row, 7) == "cancelled", do: List.replace_at(row, 9, 0), else: row
             end)

    assert Enum.map(Repo.query!("SELECT * FROM rooms ORDER BY id").rows, &Enum.take(&1, 5)) ==
             before_rooms

    for {id, policy, cutoff} <- [
          {"old", "flex-14", ~D[2028-02-16]},
          {"new", "flex-30", ~D[2028-01-31]},
          {"advance", "advance-nonrefundable", nil},
          {"refunded", "flex-14", ~D[2028-02-16]},
          {"retained", "flex-30", ~D[2028-01-31]}
        ] do
      assert %{
               policy_version: ^policy,
               refundable_until: ^cutoff,
               revision: 3,
               credit_paid_cents: 0,
               guest_id: " Guest-Ä "
             } = Reservations.get_group(id)

      assert Enum.map(Reservations.get_group(id).rooms, & &1.room_id) == ["b", "a"]
    end

    assert Reservations.get_group("old").cash_paid_cents == 1234
    assert Reservations.get_group("refunded").cash_paid_cents == 0

    assert Reservations.ledger() == %{
             cash_held_cents: 3702,
             cash_refunded_cents: 345,
             cash_retained_cents: 456,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{refunded_cents: 1234, revision: 4}, %{retained_cents: 1234, revision: 4}] =
             Reservations.submit_batch([
               operation("cancel_group", %{
                 "group_id" => "old",
                 "occurred_on" => "2028-02-10",
                 "expected_revision" => 3
               }),
               operation("cancel_group", %{
                 "group_id" => "new",
                 "occurred_on" => "2028-02-10",
                 "expected_revision" => 3
               })
             ])
  end

  test "credit lots, mixed deposits and their original allocations survive repository restarts",
       %{options: options} do
    assert [_, _, %{credit_issued_cents: 110}, _, _, _] =
             Reservations.submit_batch([
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100}),
               operation("cancel_group", %{
                 "operation_id" => "original-credit",
                 "refund_method" => "hotel_credit"
               }),
               open_operation(%{
                 "group_id" => "target",
                 "arrival_on" => "2028-01-01",
                 "departure_on" => "2028-01-04"
               }),
               operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
               operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 50})
             ])

    group = Reservations.get_group("target")
    credit = Reservations.guest_credit("guest-22", ~D[2026-11-01])
    ledger = Reservations.ledger(~D[2026-11-01])
    allocations = Repo.all(CreditAllocation)

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert Reservations.get_group("target") == group
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]) == credit
    assert Reservations.ledger(~D[2026-11-01]) == ledger
    assert Repo.all(CreditAllocation) == allocations

    assert [%{refunded_cents: 50, retained_cents: 0, credit_issued_cents: 0, revision: 4}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"group_id" => "target", "expected_revision" => 3})
             ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]) == %{
             guest_id: "guest-22",
             available_cents: 110,
             lots: [
               %{
                 source_operation_id: "original-credit",
                 remaining_cents: 110,
                 expires_on: ~D[2027-11-01]
               }
             ]
           }

    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  test "independent connections cannot double-issue, double-spend or double-restore a guest's credit",
       %{repo: repo, options: options} do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    repos = [repo, second_repo]

    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    cancellations =
      concurrent_operations(
        repos,
        List.duplicate(
          operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 2}),
          8
        )
      )

    assert Enum.count(cancellations, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(cancellations, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Repo.aggregate(CreditLot, :count) == 1

    for id <- 1..8 do
      Reservations.submit_batch([open_operation(%{"group_id" => "target-#{id}"})])
    end

    applications =
      concurrent_operations(
        repos,
        for id <- 1..8 do
          operation("apply_hotel_credit", %{
            "group_id" => "target-#{id}",
            "amount_cents" => 110,
            "expected_revision" => 1
          })
        end
      )

    assert Enum.count(applications, &(&1.status == "applied" and &1.revision == 2)) == 1
    assert Enum.count(applications, &(Map.get(&1, :code) == "insufficient_credit")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 0
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 110

    winner = Enum.find(applications, &(&1.status == "applied")).group_id

    restorations =
      concurrent_operations(
        repos,
        List.duplicate(operation("cancel_group", %{"group_id" => winner}), 8)
      )

    assert Enum.count(restorations, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(restorations, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 110
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
    assert Repo.all(CreditAllocation) == []
  end

  test "durable results and complete audit records survive database process restarts", %{
    options: options
  } do
    opening = open_operation()
    rejected = operation("cancel_group", %{"expected_revision" => 0})
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    move = operation("reschedule_group", %{"new_arrival_on" => "2027-02-01"})
    operations = [opening, rejected, payment, move]
    original = Reservations.submit_batch(operations)
    records = audit_records()
    state = domain_snapshot()

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert Reservations.submit_batch(operations) == original
    assert audit_records() == records
    assert domain_snapshot() == state
    assert Operations.get_result(rejected["operation_id"])["actual_revision"] == 1

    assert [%{code: "operation_id_conflict"}] =
             Reservations.submit_batch([Map.put(rejected, "expected_revision", 3)])

    [cancelled] = Reservations.submit_batch([operation("cancel_group")])
    assert cancelled.revision == 4
    assert List.last(audit_records()).id > List.last(records).id
  end

  test "concurrent exact retries return one result and conflicting submissions have only one winner",
       %{repo: repo, options: options} do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    repos = [repo, second_repo]
    opening = open_operation()
    openings = concurrent_operations(repos, List.duplicate(opening, 8), retry: true)

    assert Enum.uniq(openings) == [
             %{
               operation_id: opening["operation_id"],
               status: "applied",
               group_id: "group-81",
               deposit_due_cents: 19500,
               revision: 1
             }
           ]

    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    payments = concurrent_operations(repos, List.duplicate(payment, 8), retry: true)
    assert [%{revision: 2, status: "applied"}] = Enum.uniq(payments)
    assert Reservations.get_group("group-81").cash_paid_cents == 100

    conflicting =
      for amount <- 1..8,
          do: Map.merge(payment, %{"operation_id" => "race", "amount_cents" => amount})

    results = concurrent_operations(repos, conflicting, retry: true)
    assert [winner] = Enum.filter(results, &(&1.status == "applied"))
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 7
    assert Reservations.get_group("group-81").cash_paid_cents == 100 + winner.amount_cents
    assert Reservations.get_group("group-81").revision == 3

    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    cancellations = concurrent_operations(repos, List.duplicate(cancellation, 8), retry: true)
    assert [%{revision: 4, status: "applied"}] = Enum.uniq(cancellations)
    assert Repo.aggregate(CreditLot, :count) == 1

    Reservations.submit_batch([open_operation(%{"group_id" => "target"})])
    amount = hd(cancellations).credit_issued_cents

    application =
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => amount})

    applications = concurrent_operations(repos, List.duplicate(application, 8), retry: true)
    assert [%{revision: 2, status: "applied"}] = Enum.uniq(applications)
    assert Repo.aggregate(CreditAllocation, :count) == 1

    restoration = operation("cancel_group", %{"group_id" => "target"})
    restorations = concurrent_operations(repos, List.duplicate(restoration, 8), retry: true)
    assert [%{revision: 3, status: "applied"}] = Enum.uniq(restorations)
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == amount
    assert Repo.all(CreditAllocation) == []

    rejection = operation("record_cash_payment", %{"amount_cents" => 1})
    rejections = concurrent_operations(repos, List.duplicate(rejection, 8), retry: true)
    assert [%{code: "group_not_active"}] = Enum.uniq(rejections)
    assert Repo.aggregate(Operation, :count) == 8
  end

  @tag previous_release_database: true
  test "the new migration preserves previous-release accounting and starts an empty operation namespace" do
    Repo.insert!(%Group{
      group_id: "legacy",
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: ~D[2026-10-03],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-13],
      rate_plan: "flexible",
      policy_version: "flex-14",
      revision: 3,
      lodging_total_cents: 97500,
      deposit_due_cents: 19500,
      deposit_paid_cents: 1234,
      credit_paid_cents: 234
    })

    Repo.query!(
      "INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position) VALUES ('legacy', 'a', 32500, 0)"
    )

    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest-22', 'legacy-source', 100, '2027-11-01')"
    )

    [[lot_id]] = Repo.query!("SELECT id FROM credit_lots").rows
    Repo.insert!(%CreditAllocation{group_id: "legacy", credit_lot_id: lot_id, amount_cents: 234})
    before = {Repo.all(Group), Repo.all(CreditAllocation)}

    assert migrate(:up) == [
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert migrate(:up) == []
    assert {Repo.all(Group), Repo.all(CreditAllocation)} == before
    assert [%{remaining_cents: 100}] = Repo.all(CreditLot)
    assert audit_records() == []
    assert Operations.get_result("legacy-source") == nil

    cancellation = operation("cancel_group", %{"group_id" => "legacy", "expected_revision" => 3})

    assert [%{refunded_cents: 1000, revision: 4} = result] =
             Reservations.submit_batch([cancellation])

    assert Reservations.submit_batch([cancellation]) == [result]
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 334
  end

  test "an unexpected domain write failure returns 500, rolls back only that operation and stops the batch" do
    first = open_operation(%{"group_id" => "first"})

    faulty =
      open_operation(%{
        "group_id" => "faulty",
        "rooms" => [
          %{"room_id" => "good", "nightly_rate_cents" => 100},
          %{"room_id" => "fault", "nightly_rate_cents" => 100}
        ]
      })

    last = open_operation(%{"group_id" => "last"})

    Repo.query!("""
    CREATE TRIGGER fail_room BEFORE INSERT ON rooms WHEN NEW.room_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected room failure'); END
    """)

    assert_error_sent 500, fn -> post_batch([first, faulty, last]) end
    assert Reservations.get_group("first").revision == 1
    assert Reservations.get_group("faulty") == nil
    assert Reservations.get_group("last") == nil
    assert Repo.aggregate(Room, :count) == 2
    assert Enum.map(audit_records(), & &1.operation_id) == [first["operation_id"]]
    assert Operations.get_result(faulty["operation_id"]) == nil

    Repo.query!("DROP TRIGGER fail_room")
    results = post_batch([first, faulty, last]) |> json_response(200) |> Map.fetch!("results")
    assert Enum.all?(results, &(&1["status"] == "applied" and &1["revision"] == 1))
    assert Enum.map(audit_records(), & &1.submission) == [first, faulty, last]
  end

  test "failure to store the result also rolls back settlement and credit issuance" do
    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    cancellation =
      operation("cancel_group", %{
        "operation_id" => "fail-audit",
        "refund_method" => "hotel_credit"
      })

    later = open_operation(%{"group_id" => "later"})
    before = domain_snapshot()
    records = audit_records()

    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail-audit'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_error_sent 500, fn -> post_batch([cancellation, later]) end
    assert domain_snapshot() == before
    assert audit_records() == records
    assert Operations.get_result("fail-audit") == nil
    assert Operations.get_result(later["operation_id"]) == nil

    Repo.query!("DROP TRIGGER fail_audit")

    assert [%{"credit_issued_cents" => 110, "revision" => 3}, %{"revision" => 1}] =
             post_batch([cancellation, later]) |> json_response(200) |> Map.fetch!("results")

    assert Repo.aggregate(CreditLot, :count) == 1
  end

  @tag timeout: 60_000
  test "independent HTTP servers share idempotency and retain results after a full application restart",
       %{options: options} do
    {_server_a, port_a} = start_http_server(:server_a, options[:database])
    {_server_b, port_b} = start_http_server(:server_b, options[:database])
    opening = open_operation()
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    stale = operation("cancel_group", %{"expected_revision" => 1})

    reduction =
      operation("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 25
      })

    cancellation =
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"})

    chargeback =
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})

    operations = [opening, payment, stale, reduction, cancellation, chargeback]

    responses =
      [port_a, port_b, port_a, port_b, port_a, port_b]
      |> Task.async_stream(
        fn port ->
          http_request(port, :post, "/api/v1/partner-batches", %{operations: operations})
        end,
        max_concurrency: 6,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert [{200, %{"results" => original}}] = Enum.uniq(responses)

    assert [
             %{"revision" => 1},
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"revision" => 3, "amount_cents" => 25},
             %{"revision" => 4, "credit_issued_cents" => 83},
             %{"revision" => 5, "charged_back_cents" => 75}
           ] = original

    assert Reservations.get_group("group-81").cash_paid_cents == 0
    statement = http_request(port_a, :get, "/api/v1/payments/#{payment["operation_id"]}")
    state = domain_snapshot()
    records = audit_records()
    assert Enum.map(records, & &1.submission) == operations

    # Both server VMs and the local database pool stop before reading the file again.
    :ok = stop_supervised(:server_a)
    :ok = stop_supervised(:server_b)
    :ok = stop_supervised(Repo)
    {_server, restarted_port} = start_http_server(:server_restarted, options[:database])

    for {operation, result} <- Enum.zip(operations, original) do
      assert http_request(
               restarted_port,
               :get,
               "/api/v1/operations/#{URI.encode(operation["operation_id"])}"
             ) ==
               {200, %{"data" => result}}
    end

    assert http_request(restarted_port, :post, "/api/v1/partner-batches", %{
             operations: operations
           }) ==
             {200, %{"results" => original}}

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert audit_records() == records
    assert Reservations.get_group("group-81").revision == 5
    assert domain_snapshot() == state

    assert http_request(restarted_port, :get, "/api/v1/payments/#{payment["operation_id"]}") ==
             statement
  end

  test "upgrade allocates legacy funding first and durable funding by type and commit order", %{
    options: options
  } do
    source = open_operation(%{"group_id" => "source"})
    legacy_cash = operation("record_cash_payment", %{"amount_cents" => 30})
    legacy_credit = operation("apply_hotel_credit", %{"amount_cents" => 40})

    Reservations.submit_batch([
      source,
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 200}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "b", "nightly_rate_cents" => 500},
          %{"room_id" => "a", "nightly_rate_cents" => 500}
        ]
      }),
      legacy_cash,
      legacy_credit
    ])

    # These accounting facts predate the operation namespace, even though the
    # current helpers are used to build the equivalent previous-release state.
    Repo.delete_all(
      from o in Operation,
        where: o.operation_id in ^[legacy_cash["operation_id"], legacy_credit["operation_id"]]
    )

    cash =
      operation("record_cash_payment", %{"amount_cents" => 60, "occurred_on" => "2026-10-05"})

    recorded = [
      operation("apply_hotel_credit", %{"amount_cents" => 30, "occurred_on" => "2026-11-02"}),
      operation("record_cash_payment", %{"amount_cents" => 1000}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01", "amount_cents" => 999}),
      cash,
      operation("apply_hotel_credit", %{"amount_cents" => 20, "occurred_on" => "2026-10-04"})
    ]

    results = Reservations.submit_batch(recorded)
    group = Reservations.get_group("group-81")

    before =
      {Reservations.ledger(~D[2026-11-01]), Repo.all(CreditAllocation), Repo.all(CreditLot),
       audit_records()}

    assert migrate(:down, to: 20_260_905_000_003) == [
             20_260_905_000_006,
             20_260_905_000_005,
             20_260_905_000_004,
             20_260_905_000_003
           ]

    assert migrate(:up) == [
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert {Reservations.ledger(~D[2026-11-01]), Repo.all(CreditAllocation), Repo.all(CreditLot),
            audit_records()} == before

    assert Reservations.get_group("group-81") == group

    assert Enum.map(group.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) == [
             {30, 70},
             {60, 20}
           ]

    assert Reservations.submit_batch(recorded) == results
    assert Payments.statement(legacy_cash["operation_id"]) == {:error, "operation_not_found"}
    assert {:ok, %{held_cents: 60}} = Payments.statement(cash["operation_id"])

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.get_group("group-81") == group

    assert [%{refunded_cents: 30}] =
             Reservations.submit_batch([operation("cancel_rooms", %{"room_ids" => ["b"]})])

    assert [%{amount_cents: 60}] =
             Reservations.submit_batch([
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => cash["operation_id"],
                 "amount_cents" => 60
               })
             ])

    assert Reservations.get_group("group-81").credit_paid_cents == 20
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 200
  end

  test "upgrade reconciles historical dispositions and senior credit entitlements" do
    for {id, cancellation_date, method} <- [
          {"refund", "2026-11-01", "cash"},
          {"retain", "2026-12-01", "cash"},
          {"convert", "2026-11-01", "hotel_credit"}
        ] do
      legacy = operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 4})

      first =
        operation("record_cash_payment", %{
          "operation_id" => "#{id}-one",
          "group_id" => id,
          "amount_cents" => 1
        })

      second =
        operation("record_cash_payment", %{
          "operation_id" => "#{id}-two",
          "group_id" => id,
          "amount_cents" => 5
        })

      Reservations.submit_batch([
        open_operation(%{"group_id" => id}),
        legacy,
        first,
        second,
        operation("cancel_group", %{
          "group_id" => id,
          "occurred_on" => cancellation_date,
          "refund_method" => method
        })
      ])

      Repo.delete_all(from o in Operation, where: o.operation_id == ^legacy["operation_id"])
    end

    before = {Reservations.ledger(~D[2026-11-01]), audit_records()}

    assert migrate(:down, to: 20_260_905_000_003) == [
             20_260_905_000_006,
             20_260_905_000_005,
             20_260_905_000_004,
             20_260_905_000_003
           ]

    assert migrate(:up) == [
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert {Reservations.ledger(~D[2026-11-01]), audit_records()} == before
    assert {:ok, %{refunded_cents: 1, held_cents: 0}} = Payments.statement("refund-one")
    assert {:ok, %{retained_cents: 5, held_cents: 0}} = Payments.statement("retain-two")
    assert {:ok, %{converted_to_credit_cents: 1}} = Payments.statement("convert-one")

    assert [%{charged_back_cents: 1}] =
             Reservations.submit_batch([
               operation("charge_back_payment", %{"payment_operation_id" => "convert-one"})
             ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 9

    assert [%{charged_back_cents: 5}] =
             Reservations.submit_batch([
               operation("charge_back_payment", %{"payment_operation_id" => "convert-two"})
             ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 4
  end

  test "competing reductions and chargebacks serialize payment dispositions", %{
    repo: repo,
    options: options
  } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    Reservations.submit_batch([open_operation(), payment])

    reductions =
      concurrent_operations(
        [repo, second_repo],
        List.duplicate(
          operation("reduce_cash_payment", %{
            "payment_operation_id" => payment["operation_id"],
            "amount_cents" => 30
          }),
          8
        )
      )

    assert Enum.count(reductions, &(&1.status == "applied")) == 3
    assert Enum.count(reductions, &(Map.get(&1, :code) == "reduction_exceeds_held_cash")) == 5

    chargeback =
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})

    results =
      concurrent_operations([repo, second_repo], List.duplicate(chargeback, 8), retry: true)

    assert [%{charged_back_cents: 10, revision: 6}] = Enum.uniq(results)

    assert {:ok, %{held_cents: 0, reduced_cents: 90, charged_back_cents: 10}} =
             Payments.statement(payment["operation_id"])

    assert Reservations.get_group("group-81").cash_paid_cents == 0
  end

  test "audit failures roll back room settlement, reductions and credit clawbacks completely" do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    Reservations.submit_batch([open_operation(), payment])

    for op <- [
          operation("reduce_cash_payment", %{
            "payment_operation_id" => payment["operation_id"],
            "amount_cents" => 20
          }),
          operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"})
        ] do
      assert_audit_rollback(op)
    end

    Reservations.submit_batch([
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
      open_operation(%{"group_id" => "receiver"}),
      operation("apply_hotel_credit", %{"group_id" => "receiver", "amount_cents" => 80})
    ])

    assert_audit_rollback(
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})
    )
  end

  test "upgrade preserves the lot lineage of credit spent again after restoration" do
    for id <- ["first-source", "second-source"] do
      Reservations.submit_batch([
        open_operation(%{"group_id" => id}),
        operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 100}),
        operation("cancel_group", %{
          "group_id" => id,
          "operation_id" => id,
          "refund_method" => "hotel_credit"
        })
      ])
    end

    Reservations.submit_batch([
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "b", "nightly_rate_cents" => 500},
          %{"room_id" => "a", "nightly_rate_cents" => 500}
        ]
      }),
      operation("apply_hotel_credit", %{"amount_cents" => 50}),
      open_operation(%{"group_id" => "temporary"}),
      operation("apply_hotel_credit", %{"group_id" => "temporary", "amount_cents" => 60}),
      operation("apply_hotel_credit", %{"amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "temporary"}),
      operation("apply_hotel_credit", %{"amount_cents" => 50})
    ])

    lineage = fn ->
      Repo.all(
        from a in FundingAllocation,
          join: l in CreditLot,
          on: l.id == a.credit_lot_id,
          join: r in Room,
          on: r.id == a.room_id,
          where: a.group_id == "group-81",
          order_by: a.id,
          select: {r.room_id, l.source_operation_id, a.amount_cents}
      )
    end

    before = lineage.()

    assert before == [
             {"b", "first-source", 50},
             {"b", "second-source", 50},
             {"a", "second-source", 50},
             {"a", "first-source", 50}
           ]

    assert migrate(:down, to: 20_260_905_000_003) == [
             20_260_905_000_006,
             20_260_905_000_005,
             20_260_905_000_004,
             20_260_905_000_003
           ]

    assert migrate(:up) == [
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert lineage.() == before
    Reservations.submit_batch([operation("cancel_rooms", %{"room_ids" => ["b"]})])

    assert Enum.map(
             Reservations.guest_credit("guest-22", ~D[2026-11-01]).lots,
             & &1.remaining_cents
           ) == [60, 60]
  end

  test "deposit-transfer migration preserves old dispositions and supports corrections after upgrade" do
    payment = operation("record_cash_payment", %{"amount_cents" => 400})

    Reservations.submit_batch([
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => for(i <- 1..4, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
      }),
      payment,
      operation("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 25
      }),
      operation("cancel_rooms", %{"room_ids" => ["r1"]}),
      operation("cancel_rooms", %{"room_ids" => ["r2"], "occurred_on" => "2026-12-01"}),
      operation("cancel_rooms", %{"room_ids" => ["r3"], "refund_method" => "hotel_credit"}),
      open_operation(%{"group_id" => "destination"})
    ])

    before =
      {Reservations.get_group("group-81"), Reservations.ledger(~D[2026-11-01]),
       Payments.statement(payment["operation_id"]), audit_records()}

    assert migrate(:down, to: 20_260_905_000_004) == [
             20_260_905_000_006,
             20_260_905_000_005,
             20_260_905_000_004
           ]

    assert migrate(:up) == [20_260_905_000_004, 20_260_905_000_005, 20_260_905_000_006]

    assert {Reservations.get_group("group-81"), Reservations.ledger(~D[2026-11-01]),
            Payments.statement(payment["operation_id"]), audit_records()} == before

    assert [
             %{
               group_id: "group-81",
               refunded_cents: 100,
               retained_cents: 100,
               converted_to_credit_cents: 100
             }
           ] = Repo.all(PaymentSettlement)

    assert [%{source_revision: 7, destination_revision: 2}] =
             Reservations.submit_batch([transfer_operation("group-81", "destination", 50)])

    assert [%{revision: 8, charged_back_cents: 375, outstanding_deposit_cents: 100}] =
             Reservations.submit_batch([
               operation("charge_back_payment", %{
                 "payment_operation_id" => payment["operation_id"],
                 "expected_revision" => 7
               })
             ])

    assert Reservations.get_group("destination").revision == 3

    assert Reservations.ledger(~D[2026-11-01]) == %{
             cash_held_cents: 0,
             cash_refunded_cents: 0,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 25,
             cash_charged_back_cents: 375,
             credit_liability_cents: 0,
             credit_shortfall_cents: 0
           }
  end

  test "unattributed funding from an older release can transfer and settle without inventing a payment identity" do
    legacy = operation("record_cash_payment", %{"amount_cents" => 70})

    Reservations.submit_batch([
      open_operation(),
      legacy,
      open_operation(%{"group_id" => "destination"})
    ])

    Repo.delete_all(from o in Operation, where: o.operation_id == ^legacy["operation_id"])

    assert migrate(:down, to: 20_260_905_000_003) == [
             20_260_905_000_006,
             20_260_905_000_005,
             20_260_905_000_004,
             20_260_905_000_003
           ]

    assert migrate(:up) == [
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    before = Reservations.ledger(~D[2026-11-01])

    assert [%{status: "applied"}] =
             Reservations.submit_batch([transfer_operation("group-81", "destination", 30)])

    assert Reservations.ledger(~D[2026-11-01]) == before

    assert Repo.all(
             from a in FundingAllocation,
               where: a.group_id == "destination",
               select: {a.payment_operation_id, a.amount_cents}
           ) == [{nil, 30}]

    assert [%{credit_issued_cents: 33}] =
             Reservations.submit_batch([
               operation("cancel_group", %{
                 "group_id" => "destination",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert Payments.statement(legacy["operation_id"]) == {:error, "operation_not_found"}
    assert Reservations.get_group("group-81").cash_paid_cents == 40
  end

  test "competing transfers and exact retries serialize both groups", %{
    repo: repo,
    options: options
  } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    Reservations.submit_batch([
      open_operation(),
      payment,
      open_operation(%{"group_id" => "destination"})
    ])

    transfer = transfer_operation("group-81", "destination", 30)
    results = concurrent_operations([repo, second_repo], List.duplicate(transfer, 8), retry: true)
    assert [%{source_revision: 3, destination_revision: 2}] = Enum.uniq(results)
    results = concurrent_operations([repo, second_repo], List.duplicate(transfer, 8))
    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_held_funding")) == 6
    assert Reservations.get_group("group-81").revision == 5
    assert Reservations.get_group("destination").revision == 4

    assert {:ok,
            %{
              held_cents: 100,
              held_by_group: [
                %{group_id: "destination", amount_cents: 90},
                %{group_id: "group-81", amount_cents: 10}
              ]
            }} = Payments.statement(payment["operation_id"])

    competing = [
      transfer_operation("destination", "group-81", 10)
      |> Map.put("destination_expected_revision", 5),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 10,
        "expected_revision" => 5
      })
    ]

    results = concurrent_operations([repo, second_repo], competing)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 1
    assert Reservations.get_group("group-81").revision == 6
    assert Reservations.get_group("destination").revision == 5
  end

  test "audit failure rolls back both transfer participants, provenance and later cross-group corrections" do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    credit_payment =
      operation("record_cash_payment", %{"group_id" => "credit-source", "amount_cents" => 100})

    Reservations.submit_batch([
      open_operation(%{"group_id" => "credit-source"}),
      credit_payment,
      operation("cancel_group", %{
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      }),
      open_operation(),
      payment,
      operation("apply_hotel_credit", %{"amount_cents" => 100}),
      open_operation(%{"group_id" => "destination"})
    ])

    transfer = transfer_operation("group-81", "destination", 150)
    assert_audit_rollback(transfer)
    Reservations.submit_batch([transfer])

    assert_audit_rollback(
      operation("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 75
      })
    )

    Reservations.submit_batch([
      operation("cancel_group", %{"group_id" => "destination", "refund_method" => "hotel_credit"})
    ])

    assert_audit_rollback(
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})
    )
  end

  @tag timeout: 60_000
  test "transferred provenance and exact results survive concurrent HTTP retries and application restarts",
       %{options: options} do
    {_server_a, port_a} = start_http_server(:transfer_server_a, options[:database])
    {_server_b, port_b} = start_http_server(:transfer_server_b, options[:database])
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    transfer = transfer_operation("group-81", "destination", 60)

    operations = [
      open_operation(),
      open_operation(%{"group_id" => "destination"}),
      payment,
      transfer
    ]

    responses =
      [port_a, port_b, port_a, port_b]
      |> Task.async_stream(
        fn port ->
          http_request(port, :post, "/api/v1/partner-batches", %{operations: operations})
        end,
        max_concurrency: 4,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert [{200, %{"results" => original}}] = Enum.uniq(responses)
    assert List.last(original)["source_revision"] == 3
    state = domain_snapshot()
    statement = http_request(port_a, :get, "/api/v1/payments/#{payment["operation_id"]}")
    :ok = stop_supervised(:transfer_server_a)
    :ok = stop_supervised(:transfer_server_b)
    :ok = stop_supervised(Repo)
    {_server, restarted_port} = start_http_server(:transfer_server_restarted, options[:database])

    assert http_request(restarted_port, :post, "/api/v1/partner-batches", %{
             operations: operations
           }) == {200, %{"results" => original}}

    assert http_request(restarted_port, :get, "/api/v1/payments/#{payment["operation_id"]}") ==
             statement

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert domain_snapshot() == state

    assert [%{revision: 4, outstanding_deposit_cents: 19_475}] =
             Reservations.submit_batch([
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => payment["operation_id"],
                 "amount_cents" => 75
               })
             ])

    assert {:ok, %{held_by_group: [%{group_id: "group-81", amount_cents: 25}]}} =
             Payments.statement(payment["operation_id"])

    assert Reservations.get_group("destination").revision == 3
  end

  test "finance migration preserves existing accounting and reporting survives repository restarts",
       %{
         options: options
       } do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    Reservations.submit_batch([open_operation(), payment])
    state = domain_snapshot()
    assert migrate(:down, to: 20_260_905_000_005) == [20_260_905_000_006, 20_260_905_000_005]
    assert migrate(:up) == [20_260_905_000_005, 20_260_905_000_006]
    assert domain_snapshot() == state
    assert FinanceReporting.daily_report(~D[2026-11-01]) == {:error, :report_not_available}

    start = finance_start()
    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    results = Reservations.submit_batch([start, cancellation])
    assert [%{starts_on: "2026-11-01"}, %{credit_issued_cents: 110}] = results
    reports = finance_reports()
    entries = Repo.all(Entry)
    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert migrate(:up) == []
    assert finance_reports() == reports
    assert Reservations.submit_batch([start, cancellation]) == results
    assert Repo.all(Entry) == entries

    assert FinanceReporting.daily_report(~D[2027-11-02]) ==
             {:ok,
              %{
                date: ~D[2027-11-02],
                status: "open",
                late_adjustments: %{
                  cash: [],
                  credit:
                    Map.new(
                      ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
                      &{&1, 0}
                    )
                },
                cash: [],
                credit: %{
                  opening_liability_cents: 110,
                  closing_liability_cents: 0,
                  movements: %{
                    "issued_cents" => 0,
                    "expired_cents" => 110,
                    "consumed_cents" => 0,
                    "revoked_cents" => 0,
                    "absorbed_cents" => 0
                  }
                }
              }}
  end

  test "competing reporting starts and exact funding retries commit one opening and one movement",
       %{
         repo: repo,
         options: options
       } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :finance_repo))

    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results = concurrent_operations([repo, second_repo], List.duplicate(finance_start(), 8))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 7

    payment = operation("record_cash_payment", %{"amount_cents" => 50})

    assert [%{amount_cents: 50}] =
             concurrent_operations([repo, second_repo], List.duplicate(payment, 8), retry: true)
             |> Enum.uniq()

    assert {:ok, %{cash: [cash]}} = FinanceReporting.daily_report(~D[2026-11-01])
    assert cash.opening_held_cents == 100
    assert cash.movements["received_cents"] == 50
    assert cash.closing_held_cents == 150
    assert length(Repo.all(Inception)) == 1
    assert length(Repo.all(Entry)) == 2
  end

  test "start and posting failures roll back finance state with the audit and domain" do
    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    assert_audit_rollback(finance_start())
    assert FinanceReporting.daily_report(~D[2026-11-01]) == {:error, :report_not_available}
    Reservations.submit_batch([finance_start()])
    assert_audit_rollback(operation("cancel_group", %{"refund_method" => "hotel_credit"}))

    Repo.query!("""
    CREATE TRIGGER fail_finance_posting BEFORE INSERT ON finance_entries
    WHEN NEW.category = 'issued_cents'
    BEGIN SELECT RAISE(ABORT, 'injected posting failure'); END
    """)

    before = {domain_snapshot(), audit_records()}
    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    assert_error_sent 500, fn -> post_batch([cancellation]) end
    assert {domain_snapshot(), audit_records()} == before
    Repo.query!("DROP TRIGGER fail_finance_posting")
    assert [%{credit_issued_cents: 110}] = Reservations.submit_batch([cancellation])
  end

  @tag timeout: 60_000
  test "finance reports and retries survive independent HTTP servers and application restart", %{
    options: options
  } do
    {server_a, port_a} = start_http_server(:finance_server_a, options[:database])
    {server_b, port_b} = start_http_server(:finance_server_b, options[:database])
    start = finance_start()

    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      start,
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    responses =
      [port_a, port_b, port_a, port_b]
      |> Task.async_stream(
        &http_request(&1, :post, "/api/v1/partner-batches", %{operations: operations}),
        max_concurrency: 4,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.all?(responses, &match?({200, _}, &1)),
           GroupStay.ServerProcess.output(server_a) <> GroupStay.ServerProcess.output(server_b)

    assert [{200, %{"results" => original}}] = Enum.uniq(responses)
    report = http_request(port_a, :get, "/api/v1/finance/daily-report?date=2026-11-01")

    assert {200,
            %{
              "data" => %{
                "cash" => [%{"opening_held_cents" => 100}],
                "credit" => %{"closing_liability_cents" => 110}
              }
            }} = report

    reports = finance_reports()
    :ok = stop_supervised(:finance_server_a)
    :ok = stop_supervised(:finance_server_b)
    :ok = stop_supervised(Repo)
    {_server, port} = start_http_server(:finance_server_restarted, options[:database])

    # Replay first on a fresh VM, before any report read loads finance modules.
    assert http_request(port, :post, "/api/v1/partner-batches", %{operations: operations}) ==
             {200, %{"results" => original}}

    assert http_request(port, :get, "/api/v1/finance/daily-report?date=2026-11-01") == report

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert finance_reports() == reports
  end

  test "period-close migration upgrades existing finance history without changing balances or reports" do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    operations = [open_operation(), finance_start(), payment]
    results = Reservations.submit_batch(operations)
    reports = finance_reports()
    before = {domain_snapshot(), audit_records()}

    assert migrate(:down, to: 20_260_905_000_006) == [20_260_905_000_006]
    assert Repo.query!("SELECT starts_on FROM finance_reporting").rows == [["2026-11-01"]]

    assert Repo.query!("SELECT category, amount_cents FROM finance_entries").rows == [
             ["received_cents", 100]
           ]

    assert migrate(:up) == [20_260_905_000_006]
    assert {domain_snapshot(), audit_records()} == before
    assert finance_reports() == reports
    assert Reservations.submit_batch(operations) == results
    assert [%{status: "applied"}] = Reservations.submit_batch([finance_close()])
    assert {:ok, %{status: "closed"}} = FinanceReporting.daily_report(~D[2026-11-01])
  end

  test "close and late-posting audit failures roll back atomically while earlier batch effects survive" do
    Reservations.submit_batch([open_operation(), finance_start()])
    assert_audit_rollback(finance_close())
    assert Repo.get!(Inception, 1).closed_through_on == nil

    close = finance_close()
    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    failure =
      operation("record_cash_payment", %{
        "operation_id" => "fail-late-audit",
        "amount_cents" => 50
      })

    Repo.query!("""
    CREATE TRIGGER fail_late_audit BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail-late-audit'
    BEGIN SELECT RAISE(ABORT, 'injected late audit failure'); END
    """)

    assert_error_sent 500, fn -> post_batch([close, payment, failure]) end
    assert Repo.get!(Inception, 1).closed_through_on == ~D[2026-11-01]
    assert Operations.get_result(close["operation_id"])["status"] == "applied"
    assert Operations.get_result(failure["operation_id"]) == nil
    assert Reservations.get_group("group-81").cash_paid_cents == 100
    assert {:ok, %{cash: [], status: "closed"}} = FinanceReporting.daily_report(~D[2026-11-01])

    assert {:ok, %{late_adjustments: %{cash: [%{movements: %{"received_cents" => 100}}]}}} =
             FinanceReporting.daily_report(~D[2026-11-02])

    Repo.query!("DROP TRIGGER fail_late_audit")

    assert [%{status: "applied"}, %{status: "applied"}, %{status: "applied"}] =
             Reservations.submit_batch([close, payment, failure])

    assert Reservations.get_group("group-81").cash_paid_cents == 150
    assert_audit_rollback(finance_close("2026-11-02"))
    assert Repo.get!(Inception, 1).closed_through_on == ~D[2026-11-01]
    assert_audit_rollback(operation("cancel_group", %{"refund_method" => "hotel_credit"}))
  end

  test "competing closes and payments serialize cutoff selection and exact retries", %{
    repo: repo,
    options: options
  } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :close_repo))

    Reservations.submit_batch([
      open_operation(),
      finance_start(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results = concurrent_operations([repo, second_repo], List.duplicate(finance_close(), 8))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "invalid_period")) == 7
    published = FinanceReporting.daily_report(~D[2026-11-01])
    payment = operation("record_cash_payment", %{"amount_cents" => 50})

    assert [%{status: "applied", amount_cents: 50}] =
             concurrent_operations([repo, second_repo], List.duplicate(payment, 8), retry: true)
             |> Enum.uniq()

    assert FinanceReporting.daily_report(~D[2026-11-01]) == published

    # Whichever writer acquires the lock first determines which side of the
    # cutoff gets the payment. Its chosen date must survive subsequent closes.
    racing_payment = operation("record_cash_payment", %{"amount_cents" => 25})

    results =
      concurrent_operations([repo, second_repo], [finance_close("2026-11-02"), racing_payment],
        retry: true
      )

    assert Enum.all?(results, &(&1.status == "applied"))

    assert {:ok, %{late_adjustments: %{cash: [%{movements: day_two}]}}} =
             FinanceReporting.daily_report(~D[2026-11-02])

    assert {:ok, %{late_adjustments: %{cash: day_three}}} =
             FinanceReporting.daily_report(~D[2026-11-03])

    assert day_two["received_cents"] in [50, 75]

    assert day_two["received_cents"] +
             Enum.sum(Enum.map(day_three, & &1.movements["received_cents"])) == 75

    published_two = FinanceReporting.daily_report(~D[2026-11-02])
    Reservations.submit_batch([finance_close("2026-11-05")])
    assert FinanceReporting.daily_report(~D[2026-11-01]) == published
    assert FinanceReporting.daily_report(~D[2026-11-02]) == published_two
  end

  @tag timeout: 60_000
  test "closed report bytes, late postings and close retries survive concurrent HTTP servers and restarts",
       %{options: options} do
    {_server_a, port_a} = start_http_server(:close_server_a, options[:database])
    {_server_b, port_b} = start_http_server(:close_server_b, options[:database])
    start = finance_start()
    close = finance_close("2027-11-02")

    seed = [
      open_operation(),
      start,
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    assert {200, _} = http_request(port_a, :post, "/api/v1/partner-batches", %{operations: seed})

    responses =
      [port_a, port_b, port_a, port_b]
      |> Task.async_stream(
        &http_request(&1, :post, "/api/v1/partner-batches", %{operations: [close]}),
        max_concurrency: 4,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert [{200, %{"results" => [%{"status" => "applied"}]}} = close_result] =
             Enum.uniq(responses)

    paths =
      for date <- ~w(2026-11-01 2027-11-01 2027-11-02),
          do: "/api/v1/finance/daily-report?date=#{date}"

    published = Enum.map(paths, &http_request(port_a, :get, &1, nil, raw: true))

    later = [
      open_operation(%{"group_id" => "user"}),
      operation("apply_hotel_credit", %{"group_id" => "user", "amount_cents" => 80})
    ]

    assert {200, %{"results" => late_results}} =
             http_request(port_b, :post, "/api/v1/partner-batches", %{operations: later})

    assert List.last(late_results)["status"] == "applied"

    open_report =
      http_request(port_b, :get, "/api/v1/finance/daily-report?date=2027-11-03", nil, raw: true)

    assert Enum.map(paths, &http_request(port_b, :get, &1, nil, raw: true)) == published
    :ok = stop_supervised(:close_server_a)
    :ok = stop_supervised(:close_server_b)
    :ok = stop_supervised(Repo)
    {_server, port} = start_http_server(:close_server_restarted, options[:database])
    # Replay before any report read loads the new result field on the fresh VM.
    assert http_request(port, :post, "/api/v1/partner-batches", %{operations: [close]}) ==
             close_result

    assert http_request(port, :post, "/api/v1/partner-batches", %{operations: later}) ==
             {200, %{"results" => late_results}}

    assert Enum.map(paths, &http_request(port, :get, &1, nil, raw: true)) == published

    assert http_request(port, :get, "/api/v1/finance/daily-report?date=2027-11-03", nil,
             raw: true
           ) == open_report

    assert {200, _} =
             http_request(port, :post, "/api/v1/partner-batches", %{
               operations: [
                 finance_close("2027-11-03"),
                 operation("cancel_group", %{"group_id" => "user"})
               ]
             })

    assert Enum.map(paths, &http_request(port, :get, &1, nil, raw: true)) == published

    assert {200,
            %{
              "data" => %{
                "status" => "open",
                "credit" => %{"closing_liability_cents" => 0},
                "late_adjustments" => %{"credit" => %{"expired_cents" => 80}}
              }
            }} = http_request(port, :get, "/api/v1/finance/daily-report?date=2027-11-04")
  end

  defp finance_close(date \\ "2026-11-01"),
    do: %{
      "operation_id" => unique_operation_id("close"),
      "type" => "close_finance_period",
      "period_end_on" => date
    }

  defp finance_start do
    %{
      "operation_id" => unique_operation_id("start"),
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-11-01",
      "starts_on" => "2026-11-01"
    }
  end

  defp finance_reports do
    Enum.map([~D[2026-11-01], ~D[2027-11-01], ~D[2027-11-02]], &FinanceReporting.daily_report/1)
  end

  defp transfer_operation(source, destination, amount) do
    operation("transfer_deposit", %{
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    })
    |> Map.delete("group_id")
  end

  defp assert_audit_rollback(operation) do
    operation = Map.put(operation, "operation_id", "fail-current-audit")
    before = {domain_snapshot(), audit_records()}

    Repo.query!("""
    CREATE TRIGGER fail_current_audit BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail-current-audit'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    try do
      assert_error_sent 500, fn -> post_batch([operation]) end
      assert {domain_snapshot(), audit_records()} == before
    after
      Repo.query!("DROP TRIGGER fail_current_audit")
    end
  end

  defp start_http_server(id, database) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    server =
      start_supervised!(
        Supervisor.child_spec({GroupStay.ServerProcess, database: database, port: port}, id: id)
      )

    await_http(server, port, System.monotonic_time(:millisecond) + 15_000)
    {server, port}
  end

  defp await_http(server, port, deadline) do
    case http_request(port, :get, "/api/v1/operations/server-readiness") do
      {404, %{"error" => %{"code" => "operation_not_found"}}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Phoenix server did not become ready:\n#{GroupStay.ServerProcess.output(server)}")
        end

        Process.sleep(50)
        await_http(server, port, deadline)
    end
  end

  defp http_request(port, method, path, body \\ nil, opts \\ []) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500) do
      {:ok, socket} ->
        try do
          json = if body, do: Jason.encode!(body), else: ""

          request = [
            String.upcase(to_string(method)),
            " ",
            path,
            " HTTP/1.0\r\n",
            "Host: localhost\r\nConnection: close\r\nContent-Type: application/json\r\n",
            "Content-Length: ",
            Integer.to_string(byte_size(json)),
            "\r\n\r\n",
            json
          ]

          :ok = :gen_tcp.send(socket, request)
          [headers, response] = socket_response(socket, "") |> String.split("\r\n\r\n", parts: 2)
          [_, status | _] = String.split(headers, " ", parts: 3)
          {String.to_integer(status), if(opts[:raw], do: response, else: Jason.decode!(response))}
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp socket_response(socket, accumulated) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> socket_response(socket, accumulated <> data)
      {:error, :closed} -> accumulated
      {:error, reason} -> flunk("HTTP connection failed: #{inspect(reason)}")
    end
  end

  defp audit_records, do: Repo.all(from operation in Operation, order_by: operation.id)

  defp domain_snapshot,
    do:
      {Repo.all(Group), Repo.all(Room), Repo.all(CreditLot), Repo.all(CreditAllocation),
       Repo.all(FundingAllocation), Repo.all(Payment), Repo.all(CreditEntitlement),
       Repo.all(PaymentSettlement), Repo.all(Inception), Repo.all(Entry)}

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp migrate(direction, opts \\ [all: true]) do
    Ecto.Migrator.run(
      Repo,
      @migrations,
      direction,
      Keyword.put(opts, :log, false)
    )
  end

  defp remove_database_directory(directory, attempts \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _files} ->
        :ok

      {:error, reason, _path} when reason in [:eexist, :enotempty, :enoent] and attempts > 0 ->
        # Native SQLite handles can finish releasing WAL files after their owning
        # supervised processes exit. Let that cleanup finish before retrying.
        Process.sleep(20)
        remove_database_directory(directory, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  defp concurrent_operations(repos, operations, opts \\ []) do
    parent = self()

    tasks =
      operations
      |> Enum.with_index()
      |> Enum.map(fn {operation, index} ->
        Task.async(fn ->
          Repo.put_dynamic_repo(Enum.at(repos, rem(index, length(repos))))
          send(parent, {:ready, self()})

          receive do
            # These cases exercise competing distinct operations. Exact retry
            # concurrency is covered separately by the durable operations tests.
            :go ->
              operation =
                if opts[:retry],
                  do: operation,
                  else: Map.put(operation, "operation_id", unique_operation_id())

              hd(Reservations.submit_batch([operation]))
          end
        end)
      end)

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid end)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 15000))
  end
end
