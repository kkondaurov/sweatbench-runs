defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures
  import Plug.Conn
  import Phoenix.ConnTest
  import Ecto.Query

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, Room}

  @endpoint GroupStayWeb.Endpoint

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_002, GroupStay.Repo.Migrations.CreateOperations}
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
        assert migrate(:up) == [20_260_905_000_000, 20_260_905_000_001, 20_260_905_000_002]
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

    assert migrate(:down) == [20_260_905_000_002, 20_260_905_000_001, 20_260_905_000_000]
    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]
    assert migrate(:up) == [20_260_905_000_000, 20_260_905_000_001, 20_260_905_000_002]
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
      due = if status == "active", do: 19500, else: 0
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
    assert migrate(:up) == [20_260_905_000_001, 20_260_905_000_002]
    assert migrate(:up) == []

    after_groups = Repo.query!("SELECT * FROM groups ORDER BY group_id")

    assert Enum.map(after_groups.rows, &Enum.take(&1, length(before_groups.columns))) ==
             before_groups.rows

    assert Repo.query!("SELECT * FROM rooms ORDER BY id").rows == before_rooms

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

    Repo.insert!(%Room{group_id: "legacy", room_id: "a", nightly_rate_cents: 32500, position: 0})

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest-22",
        source_operation_id: "legacy-source",
        remaining_cents: 100,
        expires_on: ~D[2027-11-01]
      })

    Repo.insert!(%CreditAllocation{group_id: "legacy", credit_lot_id: lot.id, amount_cents: 234})
    before = domain_snapshot()

    assert migrate(:up) == [20_260_905_000_002]
    assert migrate(:up) == []
    assert domain_snapshot() == before
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
    operations = [opening, payment, stale]

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
             %{"code" => "stale_revision", "actual_revision" => 2}
           ] = original

    assert Reservations.get_group("group-81").cash_paid_cents == 100
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
    assert Reservations.get_group("group-81").revision == 2
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

  defp http_request(port, method, path, body \\ nil) do
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
          {String.to_integer(status), Jason.decode!(response)}
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
    do: {Repo.all(Group), Repo.all(Room), Repo.all(CreditLot), Repo.all(CreditAllocation)}

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
