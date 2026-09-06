defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Operations, Repo, Reservations}
  import Ecto.Query
  import Phoenix.ConnTest
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

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddDepositTransfers) do
      Code.require_file("priv/repo/migrations/20260905000004_add_deposit_transfers.exs")
    end

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddFinanceReporting) do
      Code.require_file("priv/repo/migrations/20260905000005_add_finance_reporting.exs")
    end

    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.AddFinancePeriodClose) do
      Code.require_file("priv/repo/migrations/20260905000006_add_finance_period_close.exs")
    end

    :ok
  end

  setup context do
    directory = Path.expand("tmp/reservations-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 10_000
    ]

    # Initialize SQLite with one connection before exercising a real connection pool.
    pid = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(pid)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)

    migrations =
      cond do
        context[:legacy] -> Enum.take(@migrations, 1)
        context[:economics] -> Enum.take(@migrations, 2)
        context[:durable] -> Enum.take(@migrations, 3)
        context[:room_accounting] -> Enum.take(@migrations, 4)
        context[:finance_reporting] -> Enum.take(@migrations, 6)
        true -> @migrations
      end

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    stop_supervised!(Repo)
    pid = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(pid)
    %{repo: pid, options: options}
  end

  defp opening do
    %{
      "operation_id" => "open-#{System.unique_integer([:positive])}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
    }
  end

  defp payment(fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-#{System.unique_integer([:positive])}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "group",
        "amount_cents" => 50
      },
      fields
    )
  end

  defp concurrent(repo, operation) do
    1..8
    |> Task.async_stream(
      fn id ->
        Repo.put_dynamic_repo(repo)
        [result] = Reservations.submit([Map.put(operation, "operation_id", "op-#{id}")])
        result
      end,
      max_concurrency: 8,
      timeout: 15_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "migrations are repeatable and reservation accounting survives repository restart", %{
    options: options
  } do
    assert [%{status: "applied"}, %{status: "applied"}] =
             Reservations.submit([opening(), payment()])

    assert [%{status: "rejected"}, %{status: "applied"}] =
             Reservations.submit([
               payment(),
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group"
               }
             ])

    group = Reservations.get_group("group")
    ledger = Reservations.ledger()

    assert ledger == %{
             cash_held_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_refunded_cents: 50,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group") == group
    assert Reservations.ledger() == ledger
  end

  test "concurrent operations can consume a revision only once", %{repo: repo} do
    Reservations.submit([opening()])
    results = concurrent(repo, payment(%{"amount_cents" => 1, "expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group").revision == 2
    assert Reservations.ledger().cash_held_cents == 1
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.submit([opening()])
    results = concurrent(repo, payment())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 7
    assert Reservations.get_group("group").outstanding_deposit_cents == 10
    assert Reservations.ledger().cash_held_cents == 50
  end

  test "concurrent duplicate openings create exactly one group", %{repo: repo} do
    results = concurrent(repo, opening())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("group").revision == 1
  end

  test "concurrent cancellations settle cash only once", %{repo: repo} do
    Reservations.submit([opening(), payment()])

    results =
      concurrent(repo, %{
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert Reservations.get_group("group").revision == 3

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_refunded_cents: 50,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag :legacy
  test "upgrade backfills original booking policies and preserves existing balances", %{
    options: options
  } do
    cases = [
      {"old", "2026-12-31", "flexible", "active", 50, 0, "flex-14", ~D[2027-02-15]},
      {"new", "2027-01-01", "flexible", "active", 40, 0, "flex-30", ~D[2027-01-30]},
      {"advance", "2026-12-31", "advance_purchase", "active", 30, 0, "advance-nonrefundable",
       nil},
      {"cancelled", "2027-01-01", "flexible", "cancelled", 0, 20, "flex-30", ~D[2027-01-30]}
    ]

    for {id, booked, plan, status, paid, refunded, _, _} <- cases do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-03-01', '2027-03-04', ?, ?, 7, ?, 300, ?, ?, ?, 0)
        """,
        [
          id,
          booked,
          plan,
          status,
          Jason.encode!(opening()["rooms"]),
          if(status == "active", do: 60, else: 0),
          paid,
          refunded
        ]
      )
    end

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_001,
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    for {id, _, _, status, paid, _, policy, deadline} <- cases do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.refundable_until == deadline
      assert group.cash_paid_cents == paid
      assert group.deposit_paid_cents == paid
      assert group.credit_paid_cents == 0
      assert group.revision == 7
      assert group.status == status
    end

    assert Reservations.ledger().cash_held_cents == 120
    assert Reservations.ledger().cash_refunded_cents == 20

    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []

    for {id, refunded, retained} <- [{"old", 50, 0}, {"new", 0, 40}, {"advance", 0, 30}] do
      assert [%{revision: 8, refunded_cents: ^refunded, retained_cents: ^retained}] =
               Reservations.submit([
                 %{
                   "operation_id" => "cancel-#{id}",
                   "type" => "cancel_group",
                   "group_id" => id,
                   "occurred_on" => "2027-02-15",
                   "expected_revision" => 7
                 }
               ])
    end
  end

  defp funded_credit do
    assert [%{status: "applied"}, %{status: "applied"}, %{credit_issued_cents: 55}] =
             Reservations.submit([
               opening(),
               payment(),
               %{
                 "operation_id" => "source",
                 "type" => "cancel_group",
                 "group_id" => "group",
                 "occurred_on" => "2026-11-26",
                 "refund_method" => "hotel_credit"
               }
             ])
  end

  defp credit_payment(group_id, amount, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "group_id" => group_id,
        "amount_cents" => amount,
        "occurred_on" => "2026-11-26"
      },
      fields
    )
  end

  test "credit lots, funding provenance and paused expiry survive repository restart", %{
    options: options
  } do
    funded_credit()

    Reservations.submit([
      Map.merge(opening(), %{
        "group_id" => "target",
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-04"
      }),
      credit_payment("target", 40)
    ])

    group = Reservations.get_group("target")
    assert group.credit_paid_cents == 40
    assert Reservations.guest_credit("guest", ~D[2027-11-26]).available_cents == 15
    assert Reservations.ledger(~D[2027-11-27]).credit_liability_cents == 40

    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Reservations.get_group("target") == group
    assert Reservations.guest_credit("guest", ~D[2027-11-26]).available_cents == 15
    assert Reservations.ledger(~D[2027-11-27]).credit_liability_cents == 40

    assert [%{revision: 3, refunded_cents: 0, retained_cents: 0, credit_issued_cents: 0}] =
             Reservations.submit([
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "group_id" => "target",
                 "occurred_on" => "2027-11-27"
               }
             ])

    assert Reservations.guest_credit("guest", ~D[2027-11-27]).available_cents == 0
    assert Reservations.ledger(~D[2027-11-27]).credit_liability_cents == 0
    assert Reservations.ledger().cash_converted_to_credit_cents == 50
  end

  test "concurrent groups cannot spend the same guest credit twice", %{repo: repo} do
    funded_credit()
    for id <- 1..8, do: Reservations.submit([Map.put(opening(), "group_id", "target-#{id}")])

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          Repo.put_dynamic_repo(repo)
          [result] = Reservations.submit([credit_payment("target-#{id}", 40)])
          result
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 7
    assert Reservations.guest_credit("guest", ~D[2026-11-26]).available_cents == 15
    assert Reservations.ledger(~D[2026-11-26]).credit_liability_cents == 55
  end

  test "concurrent credit applications consume a revision only once", %{repo: repo} do
    funded_credit()
    Reservations.submit([Map.put(opening(), "group_id", "target")])
    results = concurrent(repo, credit_payment("target", 1, %{"expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("target").revision == 2
    assert Reservations.guest_credit("guest", ~D[2026-11-26]).available_cents == 54
  end

  test "concurrent cancellations issue one credit lot", %{repo: repo} do
    Reservations.submit([opening(), payment()])

    results =
      concurrent(repo, %{
        "type" => "cancel_group",
        "group_id" => "group",
        "occurred_on" => "2026-11-26",
        "refund_method" => "hotel_credit"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert [%{remaining_cents: 55}] = Reservations.guest_credit("guest", ~D[2026-11-26]).lots
    assert Reservations.ledger(~D[2026-11-26]).cash_converted_to_credit_cents == 50
    assert Reservations.get_group("group").revision == 3
  end

  test "concurrent exact retries have one effect and one durable record", %{repo: repo} do
    Reservations.submit([opening()])
    operation = payment(%{"expected_revision" => 1})

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(repo)
          Reservations.submit([operation])
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert [%{status: "applied", revision: 2}] = Enum.uniq(results)
    assert Reservations.get_group("group").cash_paid_cents == 50
    assert Repo.aggregate(Operation, :count) == 2
  end

  test "independent connection pools serialize retries and competing payloads", %{
    options: options
  } do
    Reservations.submit([opening()])
    first = Repo.get_dynamic_repo()
    second = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    operation = payment(%{"amount_cents" => 1})

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          # Separate dynamic repos use separate local locks, exercising SQLite's
          # writer lock just as independent service instances do.
          Repo.put_dynamic_repo(if rem(id, 2) == 0, do: first, else: second)
          amount = if id <= 4, do: 1, else: 2
          [result] = Reservations.submit([Map.put(operation, "amount_cents", amount)])
          result
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    applied = Enum.filter(results, &(&1.status == "applied"))
    assert length(applied) == 4
    assert length(Enum.uniq(applied)) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 4
    assert Reservations.get_group("group").cash_paid_cents == hd(applied).amount_cents
    assert Reservations.get_group("group").revision == 2
    assert Repo.aggregate(Operation, :count) == 2
  end

  test "applied and rejected results replay after restart without any domain tables", %{
    options: options
  } do
    operations = [
      opening(),
      payment(),
      payment(%{"operation_id" => "stale", "expected_revision" => 1}),
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "group_id" => "group",
        "occurred_on" => "2026-10-03",
        "new_arrival_on" => "2027-03-01"
      }
    ]

    results = Reservations.submit(operations)
    records = Repo.all(from o in Operation, order_by: o.id)
    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))

    # A replay must not depend even on being able to read current domain state.
    Repo.query!("DROP TABLE credit_entitlements")
    Repo.query!("DROP TABLE funding_allocations")
    Repo.query!("DROP TABLE credit_allocations")
    Repo.query!("DROP TABLE credit_lots")
    Repo.query!("DROP TABLE groups")
    assert Reservations.submit(operations) == results

    for result <- results,
        do: assert(Operations.get(result.operation_id) == Jason.decode!(Jason.encode!(result)))

    assert Repo.all(from o in Operation, order_by: o.id) == records
  end

  test "handled rejection rolls back intermediate domain writes but commits the audit record" do
    submission = payment()

    assert {:ok, %{code: "insufficient_credit", status: "rejected"} = result} =
             Repo.transaction(
               fn ->
                 Operations.process(submission, fn ->
                   Repo.insert!(%CreditLot{
                     guest_id: "guest",
                     source_operation_id: "temporary",
                     remaining_cents: 10,
                     expires_on: ~D[2027-01-01]
                   })

                   Operations.reject(%{code: "insufficient_credit"})
                 end)
               end,
               mode: :immediate
             )

    assert Repo.all(CreditLot) == []
    assert Operations.get(submission["operation_id"]) == Jason.decode!(Jason.encode!(result))
    assert Reservations.submit([submission]) == [result]
  end

  test "audit insertion fault returns 500, rolls back current effects and aborts the batch" do
    open = opening()
    pay = payment()
    later = Map.put(payment(), "amount_cents", 1)

    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.type = 'record_cash_payment'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => [open, pay, later]})
    end

    assert Reservations.get_group("group").revision == 1
    assert Reservations.ledger().cash_held_cents == 0
    assert Operations.get(open["operation_id"])["status"] == "applied"
    assert Operations.get(pay["operation_id"]) == nil
    assert Operations.get(later["operation_id"]) == nil
    assert Repo.aggregate(Operation, :count) == 1

    Repo.query!("DROP TRIGGER fail_audit")
    results = Reservations.submit([open, pay, later])
    assert Enum.map(results, & &1.revision) == [1, 2, 3]
    assert Reservations.get_group("group").cash_paid_cents == 51
    assert Repo.aggregate(Operation, :count) == 3
  end

  test "a domain fault after credit issuance rolls back the lot and is retryable" do
    Reservations.submit([opening(), payment()])

    cancel = %{
      "operation_id" => "cancel",
      "type" => "cancel_group",
      "group_id" => "group",
      "occurred_on" => "2026-11-26",
      "refund_method" => "hotel_credit"
    }

    Repo.query!("""
    CREATE TRIGGER fail_settlement BEFORE UPDATE ON groups
    WHEN NEW.status = 'cancelled'
    BEGIN SELECT RAISE(ABORT, 'injected settlement failure'); END
    """)

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancel]})
    end

    assert Repo.all(CreditLot) == []
    assert Repo.get!(Group, "group").revision == 2
    assert Reservations.ledger().cash_held_cents == 50
    assert Operations.get("cancel") == nil
    Repo.query!("DROP TRIGGER fail_settlement")
    assert [%{credit_issued_cents: 55, revision: 3}] = Reservations.submit([cancel])
    assert [%{remaining_cents: 55}] = Repo.all(CreditLot)
  end

  test "full application and database process restarts preserve results", %{options: options} do
    database = options[:database]
    pay = payment()

    operations = [
      opening(),
      pay,
      payment(%{"expected_revision" => 1}),
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => pay["operation_id"],
        "amount_cents" => 10,
        "occurred_on" => "2026-11-26"
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_rooms",
        "group_id" => "group",
        "room_ids" => ["room"],
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-11-26"
      },
      %{
        "operation_id" => "charge",
        "type" => "charge_back_payment",
        "payment_operation_id" => pay["operation_id"],
        "occurred_on" => "2026-11-26"
      }
    ]

    encoded = operations |> Jason.encode!() |> Base.encode64()
    stop_supervised!(Repo)

    script = """
    operations = "#{encoded}" |> Base.decode64!() |> Jason.decode!()
    # Read before invoking Reservations, also covering a cold operation lookup.
    stored = Enum.map(operations, &GroupStay.Operations.get(&1["operation_id"]))
    results = GroupStay.Reservations.submit(operations)
    if Enum.any?(stored, & &1) and stored != Jason.decode!(Jason.encode!(results)),
      do: raise("cold audit reads differ from retry results")
    IO.puts("RESULT=" <> Jason.encode!(%{
      results: results,
      group: GroupStay.Reservations.get_group("group"),
      ledger: GroupStay.Reservations.ledger(),
      records: Enum.map(GroupStay.Repo.all(GroupStay.Operation), &Map.take(&1, [:id, :submission, :result]))
    }))
    """

    run = fn ->
      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "-e", script],
          env: [
            {"MIX_ENV", "test"},
            {"GROUP_STAY_DATABASE_PATH", database},
            {"ERL_FLAGS", "+S 2:2"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      line = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "RESULT="))
      assert line, output
      line |> String.replace_prefix("RESULT=", "") |> Jason.decode!()
    end

    first = run.()
    assert first["group"]["revision"] == 5
    assert first["ledger"]["cash_charged_back_cents"] == 40
    assert first["ledger"]["cash_reduced_cents"] == 10

    assert Enum.map(first["results"], & &1["status"]) ==
             ~w(applied applied rejected applied applied applied)

    assert run.() == first
  end

  @tag :economics
  test "upgrading the credit release preserves balances and provenance without inventing audit records" do
    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
        departure_on, rate_plan, policy_version, status, revision, rooms,
        lodging_total_cents, deposit_due_cents, deposit_paid_cents, cash_paid_cents,
        credit_paid_cents) VALUES ('group', 'guest', 'hotel', '2026-10-01',
        '2026-12-10', '2026-12-13', 'flexible', 'flex-14', 'active', 7, ?, 300, 60, 50, 20, 30)
      """,
      [Jason.encode!(opening()["rooms"])]
    )

    Repo.query!("""
    INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on)
    VALUES (1, 'guest', 'legacy-source', 25, '2027-01-01')
    """)

    allocation =
      Repo.insert!(%CreditAllocation{group_id: "group", credit_lot_id: 1, amount_cents: 30})

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_002,
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    group = Repo.get!(Group, "group")

    assert %{
             revision: 7,
             cash_paid_cents: 20,
             credit_paid_cents: 30,
             deposit_paid_cents: 50,
             deposit_due_cents: 60,
             lodging_total_cents: 300
           } = group

    lot = Repo.get!(CreditLot, 1)

    assert %{
             remaining_cents: 25,
             expires_on: ~D[2027-01-01],
             source_operation_id: "legacy-source"
           } = lot

    assert Repo.get!(CreditAllocation, allocation.id) == allocation

    assert %{cash_held_cents: 20, credit_liability_cents: 55} =
             Reservations.ledger(~D[2026-11-26])

    assert Repo.all(Operation) == []
    assert Operations.get("legacy-source") == nil

    [result] =
      Reservations.submit([
        %{
          "operation_id" => "new-namespace-cancel",
          "type" => "cancel_group",
          "group_id" => "group",
          "occurred_on" => "2026-11-26",
          "expected_revision" => 7
        }
      ])

    assert %{revision: 8, refunded_cents: 20, credit_issued_cents: 0} = result
    assert Repo.get!(CreditLot, lot.id).remaining_cents == 55
    assert Repo.all(CreditAllocation) == []
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "new operation retries remain durable across process restarts", %{options: options} do
    pay = payment()

    cancel = %{
      "operation_id" => "cancel-room",
      "type" => "cancel_rooms",
      "group_id" => "group",
      "room_ids" => ["room"],
      "occurred_on" => "2026-11-26",
      "refund_method" => "hotel_credit"
    }

    reduce = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => pay["operation_id"],
      "amount_cents" => 10,
      "occurred_on" => "2026-11-26"
    }

    charge = %{
      "operation_id" => "charge",
      "type" => "charge_back_payment",
      "payment_operation_id" => pay["operation_id"],
      "occurred_on" => "2026-11-26"
    }

    operations = [opening(), pay, reduce, cancel, charge]
    results = Reservations.submit(operations)
    assert Enum.all?(results, &(&1.status == "applied"))
    before = GroupStay.Payments.statement(pay["operation_id"])
    ledger = Reservations.ledger(~D[2026-11-26])
    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Reservations.submit(operations) == results
    assert GroupStay.Payments.statement(pay["operation_id"]) == before
    assert Reservations.ledger(~D[2026-11-26]) == ledger
    assert {:ok, %{recorded_cents: 50, reduced_cents: 10, charged_back_cents: 40}} = before
  end

  test "concurrent reductions cannot remove the same held cash twice", %{repo: repo} do
    pay = payment()
    Reservations.submit([opening(), pay])

    results =
      concurrent(repo, %{
        "type" => "reduce_cash_payment",
        "payment_operation_id" => pay["operation_id"],
        "amount_cents" => 30,
        "occurred_on" => "2026-11-26"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reduction_exceeds_held_cash")) == 7

    assert {:ok, %{held_cents: 20, reduced_cents: 30}} =
             GroupStay.Payments.statement(pay["operation_id"])

    assert Reservations.get_group("group").revision == 3
  end

  test "concurrent chargebacks revoke one entitlement and advance one revision", %{repo: repo} do
    pay = payment()

    Reservations.submit([
      opening(),
      pay,
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "group_id" => "group",
        "occurred_on" => "2026-11-26",
        "refund_method" => "hotel_credit"
      }
    ])

    results =
      concurrent(repo, %{
        "type" => "charge_back_payment",
        "payment_operation_id" => pay["operation_id"],
        "occurred_on" => "2026-11-26"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_not_chargeable")) == 7
    assert Reservations.get_group("group").revision == 4
    assert Reservations.guest_credit("guest", ~D[2026-11-26]).available_cents == 0
    assert Reservations.ledger(~D[2026-11-26]).cash_charged_back_cents == 50
    assert [%{unrecovered_clawback_cents: 0}] = Repo.all(CreditLot)
  end

  test "an audit failure rolls back chargeback dispositions and lot revocation" do
    pay = payment()

    Reservations.submit([
      opening(),
      pay,
      %{
        "operation_id" => "cancel",
        "type" => "cancel_rooms",
        "group_id" => "group",
        "room_ids" => ["room"],
        "occurred_on" => "2026-11-26",
        "refund_method" => "hotel_credit"
      }
    ])

    charge = %{
      "operation_id" => "charge",
      "type" => "charge_back_payment",
      "payment_operation_id" => pay["operation_id"],
      "occurred_on" => "2026-11-26"
    }

    before =
      Enum.map(
        [Group, CreditLot, GroupStay.FundingAllocation, GroupStay.CreditEntitlement],
        &Repo.all/1
      )

    Repo.query!("""
    CREATE TRIGGER fail_charge_audit BEFORE INSERT ON operations
    WHEN NEW.type = 'charge_back_payment'
    BEGIN SELECT RAISE(ABORT, 'injected chargeback audit failure'); END
    """)

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => [charge]})
    end

    assert Enum.map(
             [Group, CreditLot, GroupStay.FundingAllocation, GroupStay.CreditEntitlement],
             &Repo.all/1
           ) == before

    assert Operations.get("charge") == nil
    Repo.query!("DROP TRIGGER fail_charge_audit")
    assert [%{charged_back_cents: 50, revision: 4}] = Reservations.submit([charge])
  end

  @tag :durable
  test "upgrade allocates the senior block then typed durable funding in commit order" do
    rooms = for id <- ~w(b a c), do: %{"room_id" => id, "nightly_rate_cents" => 250}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_paid_cents, credit_paid_cents)
      VALUES ('group', 'guest', 'hotel', '2026-10-01', '2027-03-01', '2027-03-02',
        'flexible', 'flex-14', 'active', 9, ?, 750, 150, 140, 80, 60)
      """,
      [Jason.encode!(rooms)]
    )

    # Senior credit consumed z before a, despite the eventual expiry order.
    for {id, source, expiry, applied} <- [{1, "z", "2027-10-01", 20}, {2, "a", "2027-09-01", 40}] do
      Repo.query!(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, 10, ?)",
        [id, source, expiry]
      )

      Repo.insert!(%CreditAllocation{group_id: "group", credit_lot_id: id, amount_cents: applied})
    end

    # Cash senior = 20, credit senior = 30. Recorded cash 40 fills room a,
    # then recorded credit 30 fills a/c, then recorded cash 20 fills c.
    records =
      for {id, type, amount, date} <- [
            {"pay-first", "record_cash_payment", 40, "2026-12-01"},
            {"credit-next", "apply_hotel_credit", 30, "2026-10-02"},
            {"not-funding", "reschedule_group", 999, "2026-10-02"},
            {"pay-last", "record_cash_payment", 20, "2026-09-01"}
          ] do
        submission = %{
          "operation_id" => id,
          "type" => type,
          "group_id" => "group",
          "amount_cents" => amount,
          "occurred_on" => date
        }

        result = %{
          "operation_id" => id,
          "status" => "applied",
          "group_id" => "group",
          "revision" => 8
        }

        result =
          if type == "reschedule_group", do: result, else: Map.put(result, "amount_cents", amount)

        Repo.insert!(%Operation{
          operation_id: id,
          type: type,
          submission: submission,
          result: result
        })
      end

    balances =
      Repo.query!(
        "SELECT cash_paid_cents, credit_paid_cents, deposit_paid_cents, revision FROM groups"
      ).rows

    lots_before =
      Repo.query!("SELECT id, remaining_cents, expires_on FROM credit_lots ORDER BY id").rows

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert Repo.query!(
             "SELECT cash_paid_cents, credit_paid_cents, deposit_paid_cents, revision FROM groups"
           ).rows == balances

    assert Repo.query!("SELECT id, remaining_cents, expires_on FROM credit_lots ORDER BY id").rows ==
             lots_before

    assert Repo.all(from o in Operation, order_by: o.id) == records

    assert Enum.map(
             Reservations.get_group("group").rooms,
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{20, 30}, {40, 10}, {20, 20}]

    assert {:ok, %{held_cents: 40}} = GroupStay.Payments.statement("pay-first")
    assert {:ok, %{held_cents: 20}} = GroupStay.Payments.statement("pay-last")

    assert %{cash_held_cents: 80, credit_liability_cents: 80} =
             Reservations.ledger(~D[2026-12-01])

    assert [%{refunded_cents: 20, revision: 10}] =
             Reservations.submit([
               %{
                 "operation_id" => "cancel-senior",
                 "type" => "cancel_rooms",
                 "group_id" => "group",
                 "room_ids" => ["b"],
                 "occurred_on" => "2026-12-01"
               }
             ])

    assert Repo.get!(CreditLot, 1).remaining_cents == 30
    assert Repo.get!(CreditLot, 2).remaining_cents == 20
    assert {:ok, %{held_cents: 40}} = GroupStay.Payments.statement("pay-first")
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
  end

  @tag :durable
  test "upgrade reconciles settled durable payments and assigns senior conversion entitlement" do
    for {id, refunded, retained, converted} <- [
          {"refund", 10, 0, 0},
          {"retain", 0, 10, 0},
          {"convert", 0, 0, 10}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_paid_cents, credit_paid_cents, cash_refunded_cents,
          cash_retained_cents, cash_converted_to_credit_cents)
        VALUES (?, 'guest', 'hotel', '2026-10-01', '2027-03-01', '2027-03-02',
          'flexible', 'flex-14', 'cancelled', 9, ?, 100, 0, 0, 0, 0, ?, ?, ?)
        """,
        [
          id,
          Jason.encode!([%{"room_id" => "room", "nightly_rate_cents" => 100}]),
          refunded,
          retained,
          converted
        ]
      )

      # Four cents of senior principal, then one cent and five cents of recorded cash.
      for {suffix, amount} <- [{"first", 1}, {"last", 5}] do
        op_id = "#{id}-#{suffix}"

        submission = %{
          "operation_id" => op_id,
          "type" => "record_cash_payment",
          "group_id" => id,
          "amount_cents" => amount,
          "occurred_on" => "2026-11-01"
        }

        Repo.insert!(%Operation{
          operation_id: op_id,
          type: "record_cash_payment",
          submission: submission,
          result: %{
            "operation_id" => op_id,
            "status" => "applied",
            "group_id" => id,
            "amount_cents" => amount,
            "revision" => 2
          }
        })
      end

      cancel_id = "cancel-#{id}"

      Repo.insert!(%Operation{
        operation_id: cancel_id,
        type: "cancel_group",
        submission: %{"type" => "cancel_group", "group_id" => id},
        result: %{
          "operation_id" => cancel_id,
          "status" => "applied",
          "group_id" => id,
          "revision" => 9
        }
      })
    end

    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest', 'cancel-convert', 11, '2027-11-01')"
    )

    records = Repo.all(Operation)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_003,
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert Repo.all(Operation) == records

    assert {:ok, %{refunded_cents: 1, recorded_cents: 1}} =
             GroupStay.Payments.statement("refund-first")

    assert {:ok, %{retained_cents: 5, recorded_cents: 5}} =
             GroupStay.Payments.statement("retain-last")

    assert {:ok, %{converted_to_credit_cents: 1}} = GroupStay.Payments.statement("convert-first")
    assert Enum.map(Repo.all(GroupStay.CreditEntitlement), & &1.amount_cents) == [2, 5]

    assert [%{charged_back_cents: 1, revision: 10}] =
             Reservations.submit([
               %{
                 "operation_id" => "charge-converted",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "convert-first",
                 "occurred_on" => "2026-11-01"
               }
             ])

    assert Reservations.guest_credit("guest", ~D[2026-11-01]).available_cents == 9
    assert Reservations.ledger(~D[2026-11-01]).cash_converted_to_credit_cents == 9
  end

  @tag :durable
  test "upgrade does not attribute an earlier application to a later-issued lot" do
    rooms = for id <- ~w(first second), do: %{"room_id" => id, "nightly_rate_cents" => 500}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_paid_cents, credit_paid_cents)
      VALUES ('group', 'guest', 'hotel', '2026-10-01', '2027-03-01', '2027-03-02',
        'flexible', 'flex-14', 'active', 3, ?, 1000, 200, 200, 0, 200)
      """,
      [Jason.encode!(rooms)]
    )

    for {id, type, group, date} <- [
          {"source-first", "cancel_group", "source-1", "2026-12-01"},
          {"apply-first", "apply_hotel_credit", "group", "2026-12-01"},
          {"source-later", "cancel_group", "source-2", "2026-11-01"},
          {"apply-later", "apply_hotel_credit", "group", "2026-11-01"}
        ] do
      Repo.insert!(%Operation{
        operation_id: id,
        type: type,
        submission: %{
          "operation_id" => id,
          "type" => type,
          "group_id" => group,
          "occurred_on" => date,
          "amount_cents" => 100
        },
        result: %{
          "operation_id" => id,
          "status" => "applied",
          "group_id" => group,
          "amount_cents" => 100
        }
      })
    end

    for {id, source, expiry} <- [
          {1, "source-first", "2027-12-01"},
          {2, "source-later", "2027-11-01"}
        ] do
      Repo.query!(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, 10, ?)",
        [id, source, expiry]
      )

      Repo.insert!(%CreditAllocation{group_id: "group", credit_lot_id: id, amount_cents: 100})
    end

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

    assert [%{credit_lot_id: 1, room_id: "first"}, %{credit_lot_id: 2, room_id: "second"}] =
             Repo.all(from a in GroupStay.FundingAllocation, order_by: a.id)

    assert [%{status: "applied"}] =
             Reservations.submit([
               %{
                 "operation_id" => "cancel-first",
                 "type" => "cancel_rooms",
                 "group_id" => "group",
                 "room_ids" => ["first"],
                 "occurred_on" => "2026-12-01"
               }
             ])

    assert Repo.get!(CreditLot, 1).remaining_cents == 110
    assert Repo.get!(CreditLot, 2).remaining_cents == 10
  end

  defp transfer(fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "group",
        "destination_group_id" => "destination",
        "amount_cents" => 30,
        "occurred_on" => "2026-11-26"
      },
      fields
    )
  end

  test "transfer retries and statements survive restart without consulting domain state", %{
    options: options
  } do
    pay = payment()
    Reservations.submit([opening(), pay, Map.put(opening(), "group_id", "destination")])
    operation = transfer()
    rejected = transfer(%{"operation_id" => "rejected-transfer", "expected_revision" => 1})
    results = Reservations.submit([operation, rejected])

    assert [
             %{status: "applied", source_revision: 3, destination_revision: 2},
             %{code: "stale_revision"}
           ] = results

    before = GroupStay.Payments.statement(pay["operation_id"])
    groups = Repo.all(Group)
    ledger = Reservations.ledger()
    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert GroupStay.Payments.statement(pay["operation_id"]) == before
    assert Reservations.submit([operation, rejected]) == results
    assert Repo.all(Group) == groups
    assert Reservations.ledger() == ledger
    Repo.query!("DROP TABLE credit_entitlements")
    Repo.query!("DROP TABLE funding_allocations")
    Repo.query!("DROP TABLE credit_allocations")
    Repo.query!("DROP TABLE credit_lots")
    Repo.query!("DROP TABLE groups")
    assert Reservations.submit([operation, rejected]) == results
  end

  test "concurrent transfers serialize destination guards across independent connection pools", %{
    options: options
  } do
    Reservations.submit([opening(), payment(), Map.put(opening(), "group_id", "destination")])
    first = Repo.get_dynamic_repo()
    second = start_supervised!(Supervisor.child_spec({Repo, options}, id: :transfer_repo))
    operation = transfer(%{"amount_cents" => 1, "destination_expected_revision" => 1})

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          Repo.put_dynamic_repo(if rem(id, 2) == 0, do: first, else: second)
          [result] = Reservations.submit([Map.put(operation, "operation_id", "transfer-#{id}")])
          result
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group").revision == 3
    assert Reservations.get_group("destination").revision == 2
    assert Reservations.get_group("destination").cash_paid_cents == 1
    assert Reservations.ledger().cash_held_cents == 50

    retry = transfer(%{"operation_id" => "exact-retry", "amount_cents" => 10})

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(first)
          Reservations.submit([retry])
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert [%{status: "applied", source_revision: 4, destination_revision: 3}] =
             Enum.uniq(results)

    assert Reservations.get_group("destination").cash_paid_cents == 11
  end

  test "failed transfer audit rolls back both groups, cash provenance and applied credit" do
    funded_credit()
    destination = Map.put(opening(), "group_id", "destination")
    source = Map.put(opening(), "group_id", "source")

    Reservations.submit([
      source,
      destination,
      payment(%{"group_id" => "source", "amount_cents" => 10}),
      credit_payment("source", 40)
    ])

    operation = transfer(%{"source_group_id" => "source", "amount_cents" => 50})
    schemas = [Group, CreditLot, CreditAllocation, GroupStay.FundingAllocation, Operation]
    before = Enum.map(schemas, &Repo.all/1)

    Repo.query!("""
    CREATE TRIGGER fail_transfer_audit BEFORE INSERT ON operations
    WHEN NEW.type = 'transfer_deposit'
    BEGIN SELECT RAISE(ABORT, 'injected transfer audit failure'); END
    """)

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => [operation]})
    end

    assert Enum.map(schemas, &Repo.all/1) == before
    assert Operations.get(operation["operation_id"]) == nil
    Repo.query!("DROP TRIGGER fail_transfer_audit")
    assert [%{status: "applied"}] = Reservations.submit([operation])
    assert Reservations.get_group("destination").credit_paid_cents == 40
    assert Reservations.get_group("destination").cash_paid_cents == 10
  end

  @tag :room_accounting
  test "room-accounting database upgrades without changing balances or historical statement shapes" do
    Reservations.submit([opening(), Map.put(opening(), "group_id", "destination")])
    pay = payment(%{"amount_cents" => 40})

    result = %{
      "operation_id" => pay["operation_id"],
      "status" => "applied",
      "group_id" => "group",
      "amount_cents" => 40,
      "outstanding_deposit_cents" => 20,
      "revision" => 2
    }

    Repo.insert!(%Operation{
      operation_id: pay["operation_id"],
      type: pay["type"],
      submission: pay,
      result: result
    })

    # A senior unattributed cash block and a durable payment from release 04.
    for {payment_id, amount} <- [{nil, 10}, {pay["operation_id"], 40}] do
      Repo.query!(
        "INSERT INTO funding_allocations (group_id, room_id, payment_operation_id, kind, disposition, amount_cents) VALUES ('group', 'room', ?, 'cash', 'held', ?)",
        [payment_id, amount]
      )
    end

    group = Repo.get!(Group, "group")
    rooms = Enum.map(group.rooms, &Map.put(&1, "cash_paid_cents", 50))

    group
    |> Ecto.Changeset.change(
      rooms: rooms,
      cash_paid_cents: 50,
      deposit_paid_cents: 50,
      revision: 2
    )
    |> Repo.update!()

    before = Repo.all(Group)
    records = Repo.all(Operation)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_004,
             20_260_905_000_005,
             20_260_905_000_006
           ]

    assert Repo.all(Group) == before
    assert Repo.all(Operation) == records
    Reservations.submit([finance_start()])

    assert {:ok, %{cash: [%{opening_held_cents: 50, closing_held_cents: 50}]}} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    {:ok, statement} = GroupStay.Payments.statement(pay["operation_id"])
    refute Map.has_key?(statement, :held_by_group)
    assert statement.held_cents == 40
    assert [%{status: "applied"}] = Reservations.submit([transfer(%{"amount_cents" => 50})])
    assert Reservations.ledger().cash_held_cents == 50

    assert {:ok, %{held_by_group: [%{group_id: "destination", amount_cents: 40}]}} =
             GroupStay.Payments.statement(pay["operation_id"])

    assert [%{refunded_cents: 50}] =
             Reservations.submit([
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "group_id" => "destination",
                 "occurred_on" => "2026-11-26"
               }
             ])

    assert Reservations.ledger().cash_refunded_cents == 50

    assert GroupStay.Payments.statement("legacy-payment") ==
             {:error, :not_found, "operation_not_found"}
  end

  defp finance_start do
    %{
      "operation_id" => "finance-start",
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-11-01",
      "starts_on" => "2026-11-01"
    }
  end

  test "reporting inception, daily movements and exact retries survive repository restart", %{
    options: options
  } do
    Reservations.submit([opening(), payment()])
    start = finance_start()

    correction = %{
      "operation_id" => "finance-reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "finance-pay",
      "amount_cents" => 5,
      "occurred_on" => "2026-11-02"
    }

    pay =
      payment(%{
        "operation_id" => "finance-pay",
        "amount_cents" => 10,
        "occurred_on" => "2026-11-01"
      })

    results = Reservations.submit([start, pay, correction])
    assert Enum.all?(results, &(&1.status == "applied"))
    dates = [~D[2026-11-01], ~D[2026-11-02], ~D[2027-11-02]]
    reports = Enum.map(dates, &GroupStay.FinanceReporting.daily/1)
    entries = Repo.all(GroupStay.FinanceEntry)
    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Enum.map(dates, &GroupStay.FinanceReporting.daily/1) == reports
    assert Reservations.submit([start, pay, correction]) == results
    assert Repo.all(GroupStay.FinanceEntry) == entries
    # Reports and exact retries have no dependence on current domain tables.
    Repo.query!("DROP TABLE credit_entitlements")
    Repo.query!("DROP TABLE funding_allocations")
    Repo.query!("DROP TABLE credit_allocations")
    Repo.query!("DROP TABLE credit_lots")
    Repo.query!("DROP TABLE groups")
    assert Enum.map(dates, &GroupStay.FinanceReporting.daily/1) == reports
    assert Reservations.submit([start, pay, correction]) == results
  end

  test "concurrent starts across connection pools capture the opening only once", %{
    options: options
  } do
    Reservations.submit([opening(), payment()])
    first = Repo.get_dynamic_repo()
    second = start_supervised!(Supervisor.child_spec({Repo, options}, id: :finance_repo))

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          Repo.put_dynamic_repo(if rem(id, 2) == 0, do: first, else: second)

          [result] =
            Reservations.submit([Map.put(finance_start(), "operation_id", "start-#{id}")])

          result
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 7

    assert {:ok, %{cash: [%{opening_held_cents: 50, closing_held_cents: 50}]}} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    assert length(Repo.all(GroupStay.FinanceEntry)) == 1
  end

  test "audit failures roll back inception and movements while earlier batch commits survive" do
    Reservations.submit([opening(), payment()])

    Repo.query!("""
    CREATE TRIGGER fail_finance_start BEFORE INSERT ON operations
    WHEN NEW.type = 'start_finance_reporting'
    BEGIN SELECT RAISE(ABORT, 'injected start audit failure'); END
    """)

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => [finance_start()]})
    end

    assert Repo.all(GroupStay.FinanceEntry) == []

    assert {:error, :not_found, "report_not_available"} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    Repo.query!("DROP TRIGGER fail_finance_start")
    Reservations.submit([finance_start()])

    Repo.query!("""
    CREATE TRIGGER fail_finance_payment BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'finance-fail'
    BEGIN SELECT RAISE(ABORT, 'injected payment audit failure'); END
    """)

    good = payment(%{"amount_cents" => 5})
    bad = payment(%{"operation_id" => "finance-fail", "amount_cents" => 5})

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => [good, bad]})
    end

    assert Operations.get(bad["operation_id"]) == nil

    assert {:ok,
            %{cash: [%{opening_held_cents: 50, closing_held_cents: 55, movements: movements}]}} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    assert movements["received_cents"] == 5
    assert Reservations.ledger().cash_held_cents == 55
    Repo.query!("DROP TRIGGER fail_finance_payment")
    Reservations.submit([good, bad])

    assert {:ok, %{cash: [%{closing_held_cents: 60}]}} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])
  end

  defp finance_close(date \\ "2026-11-01") do
    %{
      "operation_id" => "finance-close-#{date}",
      "type" => "close_finance_period",
      "period_end_on" => date
    }
  end

  test "closed data, late postings and close replays survive database and application restarts",
       %{
         options: options
       } do
    close = finance_close()
    late = payment(%{"amount_cents" => 5})
    results = Reservations.submit([opening(), finance_start(), payment(), close, late])
    assert Enum.all?(results, &(&1.status == "applied"))
    dates = [~D[2026-11-01], ~D[2026-11-02]]
    reports = Enum.map(dates, &GroupStay.FinanceReporting.daily/1)
    entries = Repo.all(GroupStay.FinanceEntry)
    stop_supervised!(Repo)
    Repo.put_dynamic_repo(start_supervised!({Repo, options}))
    assert Enum.map(dates, &GroupStay.FinanceReporting.daily/1) == reports
    assert Reservations.submit([close, late]) == Enum.take(results, -2)
    assert Repo.all(GroupStay.FinanceEntry) == entries

    wire_reports =
      Enum.map(dates, fn date ->
        get(build_conn(), "/api/v1/finance/daily-report?date=#{date}").resp_body
      end)

    script = """
    reports = Enum.map([~D[2026-11-01], ~D[2026-11-02]], fn date ->
      conn = Plug.Test.conn(:get, "/api/v1/finance/daily-report?date=" <> Date.to_iso8601(date))
      GroupStayWeb.Endpoint.call(conn, GroupStayWeb.Endpoint.init([])).resp_body
    end)
    IO.puts("REPORTS=" <> Jason.encode!(reports))
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "-e", script],
        env: [
          {"MIX_ENV", "test"},
          {"GROUP_STAY_DATABASE_PATH", options[:database]},
          {"ERL_FLAGS", "+S 2:2"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    line = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "REPORTS="))
    assert line == "REPORTS=" <> Jason.encode!(wire_reports)

    Reservations.submit([finance_close("2026-11-02"), payment(%{"amount_cents" => 5})])
    assert GroupStay.FinanceReporting.daily(hd(dates)) == hd(reports)
    assert Reservations.submit([close, late]) == Enum.take(results, -2)
    # Neither closed reports nor exact replays depend on current domain state.
    Repo.query!("DROP TABLE credit_entitlements")
    Repo.query!("DROP TABLE funding_allocations")
    Repo.query!("DROP TABLE credit_allocations")
    Repo.query!("DROP TABLE credit_lots")
    Repo.query!("DROP TABLE groups")
    assert GroupStay.FinanceReporting.daily(hd(dates)) == hd(reports)
    assert Reservations.submit([close, late]) == Enum.take(results, -2)
  end

  test "competing closes across connection pools commit only one cutoff", %{options: options} do
    Reservations.submit([opening(), finance_start(), payment()])
    first = Repo.get_dynamic_repo()
    second = start_supervised!(Supervisor.child_spec({Repo, options}, id: :close_repo))

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          Repo.put_dynamic_repo(if rem(id, 2) == 0, do: first, else: second)

          [result] =
            Reservations.submit([Map.put(finance_close(), "operation_id", "close-#{id}")])

          result
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "invalid_period")) == 7
    assert {:ok, %{status: "closed"}} = GroupStay.FinanceReporting.daily(~D[2026-11-01])

    retry = finance_close("2026-11-02")

    results =
      1..8
      |> Task.async_stream(
        fn id ->
          Repo.put_dynamic_repo(if rem(id, 2) == 0, do: first, else: second)
          Reservations.submit([retry])
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert [%{status: "applied"}] = Enum.uniq(results)

    assert Repo.aggregate(
             from(o in Operation, where: o.operation_id == ^retry["operation_id"]),
             :count
           ) == 1
  end

  test "failed close audit leaves the period open and earlier batch movements committed" do
    Reservations.submit([opening(), finance_start()])

    Repo.query!("""
    CREATE TRIGGER fail_finance_close BEFORE INSERT ON operations
    WHEN NEW.type = 'close_finance_period'
    BEGIN SELECT RAISE(ABORT, 'injected close audit failure'); END
    """)

    before_close = payment(%{"amount_cents" => 10})
    after_close = payment(%{"amount_cents" => 5})
    close = finance_close()

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [before_close, close, after_close]
      })
    end

    assert Operations.get(close["operation_id"]) == nil
    assert Operations.get(after_close["operation_id"]) == nil

    assert {:ok,
            %{status: "open", cash: [%{closing_held_cents: 10}], late_adjustments: %{cash: []}}} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    Repo.query!("DROP TRIGGER fail_finance_close")
    Reservations.submit([before_close, close, after_close])

    assert {:ok, %{status: "closed", cash: [%{closing_held_cents: 10}]}} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    assert {:ok,
            %{
              cash: [%{closing_held_cents: 15}],
              late_adjustments: %{cash: [%{movements: movements}]}
            }} =
             GroupStay.FinanceReporting.daily(~D[2026-11-02])

    assert movements["received_cents"] == 5
  end

  @tag :finance_reporting
  test "upgrading a reporting database preserves existing movements and scheduled expiry" do
    # Seed the previous release's wire audit and SQL schema without using new fields.
    Repo.insert!(%Operation{
      operation_id: "old-start",
      type: "start_finance_reporting",
      submission: %{
        "operation_id" => "old-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-11-01"
      },
      result: %{"operation_id" => "old-start", "status" => "applied", "starts_on" => "2026-11-01"}
    })

    for {date, property, classification, amount} <- [
          {"2026-11-01", "hotel", "opening", 100},
          {"2026-11-01", "hotel", "received_cents", 20},
          {"2026-11-01", nil, "opening", 110},
          {"2027-11-02", nil, "expired_cents", 110}
        ] do
      Repo.query!(
        "INSERT INTO finance_entries (operation_id, posted_on, property_id, classification, amount_cents) VALUES ('old-start', ?, ?, ?, ?)",
        [date, property, classification, amount]
      )
    end

    records = Repo.all(Operation)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_006
           ]

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Repo.all(Operation) == records
    assert Enum.all?(Repo.all(GroupStay.FinanceEntry), &(&1.late_adjustment == false))

    assert {:ok,
            %{
              cash: [%{opening_held_cents: 100, closing_held_cents: 120}],
              late_adjustments: %{cash: []}
            }} =
             GroupStay.FinanceReporting.daily(~D[2026-11-01])

    assert {:ok,
            %{
              credit: %{
                opening_liability_cents: 110,
                closing_liability_cents: 0,
                movements: movements
              }
            }} =
             GroupStay.FinanceReporting.daily(~D[2027-11-02])

    assert movements["expired_cents"] == 110
    assert [%{status: "applied"}] = Reservations.submit([finance_close("2027-11-02")])
    assert {:ok, %{status: "closed"}} = GroupStay.FinanceReporting.daily(~D[2027-11-02])
  end
end
