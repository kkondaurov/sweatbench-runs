defmodule GroupStay.OperationsPersistenceTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.PartnerOperations
  import Ecto.Query
  import Plug.Conn
  import Phoenix.ConnTest

  alias GroupStay.{Operations, PartnerBatches, Repo, Reservations}
  alias GroupStay.HotelCredit.{Application, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.{Group, Room}

  @endpoint GroupStayWeb.Endpoint

  test "concurrent exact openings, payments, rejections and credit settlements commit once" do
    opening = open_group()
    [opened] = race(opening)
    assert opened["revision"] == 1
    assert Repo.aggregate(Room, :count) == 2

    [paid] = race(payment(%{"expected_revision" => 1}))
    assert paid["revision"] == 2
    assert Reservations.ledger().cash_held_cents == 1_000

    [rejected] = race(payment(%{"expected_revision" => 1}))
    assert rejected["actual_revision"] == 2
    assert rejected["code"] == "stale_revision"

    [cancelled] =
      race(cancellation(%{"refund_method" => "hotel_credit", "expected_revision" => 2}))

    assert cancelled["credit_issued_cents"] == 1_100
    assert Repo.aggregate(Lot, :count) == 1
    assert Repo.aggregate(Operation, :count) == 4

    Operations.process(open_group(%{"group_id" => "target"}))
    [applied] = race(credit_payment(%{"group_id" => "target", "expected_revision" => 1}))
    assert applied["revision"] == 2
    assert Repo.aggregate(Application, :count) == 1
    assert Repo.get!(Group, "target").credit_paid_cents == 1_000
    assert GroupStay.HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 100

    [restored] = race(cancellation(%{"group_id" => "target", "expected_revision" => 2}))
    assert restored["credit_issued_cents"] == 0
    assert GroupStay.HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 1_100
    assert Repo.aggregate(Operation, :count) == 7
  end

  test "concurrent different payloads sharing an ID preserve the winner and commit order" do
    Operations.process(open_group())

    payments =
      for amount <- 1..8, do: payment(%{"operation_id" => "contested", "amount_cents" => amount})

    results = concurrently(payments, @repo_name)
    assert [winner] = Enum.filter(results, &(&1["status"] == "applied"))
    assert Enum.count(results, &(&1["code"] == "operation_id_conflict")) == 7
    assert Repo.get!(Group, "group-81").deposit_paid_cents == winner["amount_cents"]
    assert Operations.get_result("contested") == winner
    assert Repo.aggregate(Operation, :count) == 2

    # Distinct first submissions serialize too. Their generated record IDs follow
    # the revisions established by that same commit order, regardless of arrival.
    results = concurrently(for(_ <- 1..8, do: payment()), @repo_name)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    records = Repo.all(from operation in Operation, order_by: operation.id)
    assert Enum.map(records, & &1.result["revision"]) == Enum.to_list(1..10)
  end

  test "audit insertion failure rolls back domain writes, returns 500 and stops the batch" do
    opening = open_group()
    payment = payment(%{"operation_id" => "fault"})
    later = reschedule()
    operations = [opening, payment, later]

    Repo.query!("""
    CREATE TRIGGER fail_operation_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    try do
      assert {500, _headers, body} = assert_error_sent(500, fn -> post_batch(operations) end)
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
      assert %Group{revision: 1, deposit_paid_cents: 0} = Reservations.get_group("group-81")
      assert Operations.get_result(opening["operation_id"])["revision"] == 1
      assert Operations.get_result("fault") == nil
      assert Operations.get_result(later["operation_id"]) == nil
      assert Repo.aggregate(Operation, :count) == 1
      assert Reservations.ledger().cash_held_cents == 0
    after
      Repo.query!("DROP TRIGGER fail_operation_audit")
    end

    results = post_batch(operations) |> json_response(200) |> Map.fetch!("results")
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3]
    assert Reservations.ledger().cash_held_cents == 1_000
    assert Repo.aggregate(Operation, :count) == 3
  end

  test "a fault after credit restoration and issuance rolls back the whole settlement" do
    submit([
      open_group(%{"group_id" => "source"}),
      payment(%{"group_id" => "source"}),
      cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_group(),
      payment(%{"amount_cents" => 505}),
      credit_payment(%{"amount_cents" => 600})
    ])

    operation = cancellation(%{"refund_method" => "hotel_credit"})
    before = snapshot()

    Repo.query!("""
    CREATE TRIGGER fail_settlement BEFORE UPDATE ON groups
    WHEN NEW.group_id = 'group-81' AND NEW.status = 'cancelled'
    BEGIN SELECT RAISE(ABORT, 'injected settlement failure'); END
    """)

    try do
      assert_error_sent(500, fn -> post_batch([operation]) end)
      assert snapshot() == before
      assert Operations.get_result(operation["operation_id"]) == nil
    after
      Repo.query!("DROP TRIGGER fail_settlement")
    end

    assert [%{"credit_issued_cents" => 556, "revision" => 4} = result] = submit([operation])
    assert submit([operation]) == [result]
    assert GroupStay.HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 1_656
    assert Reservations.ledger(~D[2026-11-01]).cash_converted_to_credit_cents == 1_505
  end

  test "stored payloads, rejections, results and ordering survive a database process restart", %{
    repo_options: options
  } do
    operations = [
      open_group(),
      payment(),
      payment(%{"expected_revision" => 1}),
      cancellation(%{"refund_method" => "hotel_credit"})
    ]

    results = submit(operations)
    before = snapshot()

    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    assert submit(operations) === results
    assert Enum.map(operations, &Operations.get_result(&1["operation_id"])) === results
    assert snapshot() == before
    [first | _] = before.operations

    assert Operations.process(Map.put(hd(operations), "guest_id", "changed"))["code"] ==
             "operation_id_conflict"

    assert Repo.get!(Operation, first.id) == first

    Operations.process(open_group(%{"group_id" => "later"}))
    assert List.last(records()).id > List.last(before.operations).id
  end

  test "a fresh application VM replays durable operations from the same database", %{
    repo_options: options
  } do
    directory = Path.dirname(options[:database])
    payload_path = Path.join(directory, "restart-batch.json")
    script_path = Path.join(directory, "restart.exs")

    operations = [
      open_group(),
      payment(),
      payment(%{"expected_revision" => 1}),
      cancellation(%{"refund_method" => "hotel_credit"})
    ]

    File.write!(payload_path, Jason.encode!(%{"operations" => operations}))

    File.write!(script_path, """
    import Ecto.Query
    alias GroupStay.{Operations, PartnerBatches, Repo, Reservations}
    alias GroupStay.Operations.Operation

    [payload_path] = System.argv()
    batch = payload_path |> File.read!() |> Jason.decode!()
    {:ok, results} = PartnerBatches.submit(batch)

    records =
      Repo.all(from operation in Operation, order_by: operation.id)
      |> Enum.map(&Map.take(&1, [:id, :operation_id, :type, :payload, :result]))

    output = %{
      results: results,
      lookups: Enum.map(batch["operations"], &Operations.get_result(&1["operation_id"])),
      records: records,
      ledger: Reservations.ledger(~D[2026-11-01])
    }

    IO.puts("DURABLE_RESULTS=" <> Jason.encode!(output))
    """)

    run = fn ->
      {output, status} =
        System.cmd("mix", ["run", "--no-compile", script_path, payload_path],
          env: [
            {"MIX_ENV", "test"},
            {"GROUP_STAY_DATABASE_PATH", options[:database]},
            {"ERL_FLAGS", "+S 2:2"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output

      line =
        output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "DURABLE_RESULTS="))

      assert line, output
      line |> String.replace_prefix("DURABLE_RESULTS=", "") |> Jason.decode!()
    end

    first = run.()
    assert run.() === first
    assert first["lookups"] === first["results"]
    assert Enum.map(first["records"], & &1["payload"]) === operations
    assert Enum.at(first["results"], 2)["actual_revision"] == 2
    assert first["ledger"]["cash_converted_to_credit_cents"] == 1_000
    assert first["ledger"]["credit_liability_cents"] == 1_100
    assert Reservations.get_group("group-81").revision == 3
  end

  defp race(operation) do
    results = concurrently(List.duplicate(operation, 8), @repo_name)
    assert length(Enum.uniq(results)) == 1
    assert Operations.get_result(operation["operation_id"]) == hd(results)
    Enum.uniq(results)
  end

  defp submit(operations) do
    {:ok, results} = PartnerBatches.submit(%{"operations" => operations})
    results
  end

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp records, do: Repo.all(from operation in Operation, order_by: operation.id)

  defp snapshot do
    %{
      groups: Repo.all(Group),
      rooms: Repo.all(Room),
      lots: Repo.all(Lot),
      applications: Repo.all(Application),
      operations: records()
    }
  end
end
