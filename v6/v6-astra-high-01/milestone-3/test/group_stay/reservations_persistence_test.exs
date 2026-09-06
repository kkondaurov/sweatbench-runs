defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Operations, Repo, Reservations}
  import Ecto.Query
  import Phoenix.ConnTest
  @endpoint GroupStayWeb.Endpoint

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_002, GroupStay.Repo.Migrations.CreateOperations}
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
             20_260_905_000_002
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
    operations = [opening(), payment(), payment(%{"expected_revision" => 1})]
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
    assert first["group"]["revision"] == 2
    assert Enum.map(first["results"], & &1["status"]) == ~w(applied applied rejected)
    assert run.() == first
  end

  @tag :economics
  test "upgrading the credit release preserves balances and provenance without inventing audit records" do
    group =
      Repo.insert!(%Group{
        group_id: "group",
        guest_id: "guest",
        property_id: "hotel",
        booked_on: ~D[2026-10-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        policy_version: "flex-14",
        rooms: opening()["rooms"],
        lodging_total_cents: 300,
        deposit_due_cents: 60,
        deposit_paid_cents: 50,
        cash_paid_cents: 20,
        credit_paid_cents: 30,
        revision: 7
      })

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest",
        source_operation_id: "legacy-source",
        remaining_cents: 25,
        expires_on: ~D[2027-01-01]
      })

    allocation =
      Repo.insert!(%CreditAllocation{
        group_id: group.group_id,
        credit_lot_id: lot.id,
        amount_cents: 30
      })

    ledger = Reservations.ledger(~D[2026-11-26])

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_905_000_002
           ]

    assert Repo.get!(Group, group.group_id) == group
    assert Repo.get!(CreditLot, lot.id) == lot
    assert Repo.get!(CreditAllocation, allocation.id) == allocation
    assert Reservations.ledger(~D[2026-11-26]) == ledger
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
end
