defmodule GroupStay.DurableOperationsPersistenceTest do
  use GroupStay.PersistenceCase

  import Ecto.Query
  import GroupStay.OperationFixtures
  import Phoenix.ConnTest
  import Plug.Conn

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CashEntry, CreditAllocation, CreditLot, Group, OperationRecord}

  @endpoint GroupStayWeb.Endpoint

  test "concurrent batch retries commit cash, credit, revisions and audit records only once", %{
    repo: repo
  } do
    operations = [
      open_group(),
      payment(%{"expected_revision" => 1}),
      cancellation(%{"refund_method" => "hotel_credit", "expected_revision" => 2}),
      open_group(%{"group_id" => "target"}),
      credit_application(%{"group_id" => "target", "expected_revision" => 1}),
      payment(%{"group_id" => "target", "amount_cents" => 5, "expected_revision" => 2}),
      cancellation(%{
        "group_id" => "target",
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      })
    ]

    [first | retries] = race(repo, fn _ -> Reservations.submit_batch(operations) end)
    assert Enum.all?(first, &(&1["status"] == "applied"))
    assert Enum.all?(retries, &(&1 === first))
    assert Enum.map(records(), & &1.submission) === operations
    assert Enum.map(records(), & &1.result) === first
    assert Repo.aggregate(CashEntry, :count) == 4
    assert Repo.aggregate(CreditLot, :count) == 2
    assert Repo.aggregate(CreditAllocation, :count) == 1
    assert Reservations.get_group("group-81").revision == 3
    assert Reservations.get_group("target").revision == 4
    assert Reservations.ledger(~D[2026-11-01]).cash_converted_to_credit_cents == 5_005
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 5_506
  end

  test "concurrent different payloads reserve an identifier for exactly one submission", %{
    repo: repo
  } do
    Reservations.submit_batch([open_group()])

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            payment(%{
              "operation_id" => "contested",
              "amount_cents" => index * 1_000,
              "expected_revision" => 1
            })
          ])

        result
      end)

    assert [applied] = Enum.filter(results, &(&1["status"] == "applied"))
    assert Enum.count(results, &(&1["code"] == "operation_id_conflict")) == 3
    assert Reservations.get_operation_result("contested") === applied
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == applied["amount_cents"]
    assert Repo.aggregate(CashEntry, :count) == 1
    assert length(records()) == 2
    assert List.last(records()).submission["amount_cents"] == applied["amount_cents"]
  end

  test "concurrent rejected retries commit one audit record and no domain changes", %{repo: repo} do
    operation = payment(%{"operation_id" => "missing-group", "expected_revision" => 99})
    results = race(repo, fn _ -> Reservations.submit_batch([operation]) end)
    [first | retries] = results
    assert [%{"code" => "group_not_found"}] = first
    assert Enum.all?(retries, &(&1 === first))
    assert Repo.all(Group) == []
    assert Repo.all(CashEntry) == []
    assert [%OperationRecord{submission: ^operation}] = records()
  end

  test "retries and result lookups do not read current domain state" do
    operations = [
      open_group(),
      payment(),
      reschedule(),
      cancellation(%{"expected_revision" => 1}),
      cancellation()
    ]

    results = Reservations.submit_batch(operations)
    before = snapshot()

    # Any attempt to reevaluate a booking would now fail its group query.
    Repo.query!("ALTER TABLE groups RENAME TO temporarily_unavailable_groups")
    assert Reservations.submit_batch(operations) === results

    for {operation, result} <- Enum.zip(operations, results) do
      assert Reservations.get_operation_result(operation["operation_id"]) === result
    end

    [conflict] =
      Reservations.submit_batch([Map.put(hd(operations), "group_id", "another-group")])

    assert conflict["code"] == "operation_id_conflict"
    Repo.query!("ALTER TABLE temporarily_unavailable_groups RENAME TO groups")
    assert snapshot() == before
  end

  test "an audit failure while storing a rejection leaves the identifier available for retry" do
    operation = payment(%{"expected_revision" => 1})

    Repo.query!("""
    CREATE TRIGGER reject_operation_record BEFORE INSERT ON operation_records
    BEGIN
      SELECT RAISE(ABORT, 'simulated audit storage failure');
    END
    """)

    assert_raise Exqlite.Error, ~r/simulated audit storage failure/, fn ->
      Reservations.submit_batch([operation])
    end

    assert records() == []
    assert Reservations.get_operation_result(operation["operation_id"]) == nil
    Repo.query!("DROP TRIGGER reject_operation_record")

    assert [%{"revision" => 1}, %{"revision" => 2}] =
             Reservations.submit_batch([open_group(), operation])
  end

  test "audit persistence failure returns HTTP 500 and rolls back only the current operation" do
    opening = open_group()
    funding = payment(%{"operation_id" => "fail-record", "expected_revision" => 1})
    later = reschedule(%{"expected_revision" => 2})
    operations = [opening, funding, later]

    Repo.query!("""
    CREATE TRIGGER reject_operation_record BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fail-record'
    BEGIN
      SELECT RAISE(ABORT, 'simulated audit storage failure');
    END
    """)

    assert_error_sent 500, fn -> post_batch(operations) end

    assert Reservations.get_group("group-81").revision == 1
    assert Reservations.ledger().cash_held_cents == 0
    assert Repo.all(CashEntry) == []
    assert Reservations.get_operation_result(funding["operation_id"]) == nil
    assert Reservations.get_operation_result(later["operation_id"]) == nil
    assert Enum.map(records(), & &1.submission) == [opening]

    Repo.query!("DROP TRIGGER reject_operation_record")

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(operations) |> json_response(200)

    assert Reservations.ledger().cash_held_cents == 5_000
    assert Repo.aggregate(CashEntry, :count) == 1
    assert Enum.map(records(), & &1.submission) == operations
  end

  test "a domain storage fault is not remembered and aborts later batch operations" do
    opening = open_group()
    funding = payment()
    later = cancellation()

    Repo.query!("""
    CREATE TRIGGER reject_cash_entry BEFORE INSERT ON cash_entries
    BEGIN
      SELECT RAISE(ABORT, 'simulated cash storage failure');
    END
    """)

    assert_error_sent 500, fn -> post_batch([opening, funding, later]) end

    assert Reservations.get_group("group-81").revision == 1
    assert Reservations.get_operation_result(funding["operation_id"]) == nil
    assert Reservations.get_operation_result(later["operation_id"]) == nil
    assert Enum.map(records(), & &1.submission) == [opening]

    Repo.query!("DROP TRIGGER reject_cash_entry")

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch([opening, funding, later]) |> json_response(200)

    assert Reservations.ledger().cash_refunded_cents == 5_000
    assert Repo.aggregate(CashEntry, :count) == 2
  end

  test "failed audit insertion rolls back restored credit, bonus issuance and cancellation" do
    Reservations.submit_batch([
      open_group(),
      payment(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "target"}),
      credit_application(%{"group_id" => "target"}),
      payment(%{"group_id" => "target"})
    ])

    operation = cancellation(%{"group_id" => "target", "refund_method" => "hotel_credit"})
    before = snapshot()

    Repo.query!("""
    CREATE TRIGGER reject_operation_record BEFORE INSERT ON operation_records
    BEGIN
      SELECT RAISE(ABORT, 'simulated audit storage failure');
    END
    """)

    assert_raise Exqlite.Error, ~r/simulated audit storage failure/, fn ->
      Reservations.submit_batch([operation])
    end

    assert snapshot() == before
    assert Reservations.get_operation_result(operation["operation_id"]) == nil

    Repo.query!("DROP TRIGGER reject_operation_record")

    assert [%{"revision" => 4, "credit_issued_cents" => 5_500}] =
             Reservations.submit_batch([operation])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 11_000
  end

  test "rejected results and date-bearing results survive database process restarts", %{
    options: options
  } do
    operations = [
      payment(),
      open_group(),
      payment(%{"expected_revision" => 1}),
      reschedule(%{"expected_revision" => 2}),
      cancellation(%{"expected_revision" => 1}),
      cancellation(%{"refund_method" => "hotel_credit", "expected_revision" => 3})
    ]

    results = Reservations.submit_batch(operations)
    before = snapshot()

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert snapshot() == before
    assert Reservations.submit_batch(operations) === results

    for {operation, result} <- Enum.zip(operations, results) do
      assert Reservations.get_operation_result(operation["operation_id"]) === result
    end

    assert snapshot() == before

    [conflict] =
      Reservations.submit_batch([Map.put(Enum.at(operations, 4), "expected_revision", 4)])

    assert conflict["code"] == "operation_id_conflict"
    assert snapshot() == before

    previous_records = records()
    next = open_group(%{"group_id" => "after-restart", "operation_id" => "a-after-restart"})
    assert [%{"revision" => 1}] = Reservations.submit_batch([next])
    assert Enum.drop(records(), -1) == previous_records
    assert List.last(records()).id > List.last(previous_records).id
    assert List.last(records()).submission == next
  end

  test "first attempts and retries agree across independent application lifetimes", %{
    database: database
  } do
    directory = Path.dirname(database)
    script = Path.join(directory, "submit.exs")
    input = Path.join(directory, "operations.json")
    output = Path.join(directory, "results.json")

    operations = [
      payment(),
      open_group(),
      payment(),
      reschedule(),
      cancellation(%{"refund_method" => "hotel_credit"})
    ]

    File.write!(input, Jason.encode!(operations))

    File.write!(script, """
    [input, output] = System.argv()
    results = input |> File.read!() |> Jason.decode!() |> GroupStay.Reservations.submit_batch()
    File.write!(output, Jason.encode!(results))
    """)

    run = fn ->
      {log, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", script, input, output],
          env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", database}],
          stderr_to_stdout: true
        )

      assert status == 0, log
      output |> File.read!() |> Jason.decode!()
    end

    results = run.()
    assert [%{"code" => "group_not_found"} | _] = results
    assert List.last(results)["revision"] == 4
    before = snapshot()
    assert run.() === results
    assert snapshot() == before
    assert Enum.map(records(), & &1.submission) == operations
  end

  test "migration upgrades the previous release without inventing records for earlier operations" do
    # Release 02 already supported all these domain facts. Removing only the
    # journal recreates its database layout with cash and credit history intact.
    Reservations.submit_batch([
      open_group(%{"group_id" => "source"}),
      payment(%{"group_id" => "source"}),
      cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_group(),
      payment(%{"operation_id" => "legacy-payment"}),
      credit_application(%{"amount_cents" => 500})
    ])

    migration = [{20_260_907_000_002, GroupStay.Repo.Migrations.CreateOperationRecords}]
    assert Ecto.Migrator.run(Repo, migration, :down, step: 1, log: false) == [20_260_907_000_002]
    before = domain_snapshot()

    assert Ecto.Migrator.run(Repo, migration, :up, all: true, log: false) == [20_260_907_000_002]
    assert domain_snapshot() == before
    assert records() == []
    assert Reservations.get_operation_result("legacy-payment") == nil
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 5_500

    operation = payment(%{"operation_id" => "new-payment", "expected_revision" => 3})
    assert [%{"revision" => 4} = result] = Reservations.submit_batch([operation])
    assert Reservations.submit_batch([operation]) === [result]
    assert Reservations.get_group("group-81").deposit_paid_cents == 10_500
    assert Enum.map(records(), & &1.submission) == [operation]
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp records, do: Repo.all(from record in OperationRecord, order_by: record.id)

  defp snapshot, do: domain_snapshot() ++ [records()]

  defp domain_snapshot do
    for schema <- [Group, CashEntry, CreditLot, CreditAllocation] do
      Repo.all(from record in schema, order_by: ^schema.__schema__(:primary_key))
    end
  end
end
