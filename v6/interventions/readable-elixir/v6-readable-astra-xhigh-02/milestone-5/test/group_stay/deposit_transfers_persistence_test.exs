defmodule GroupStay.DepositTransfersPersistenceTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import Plug.Conn
  import Phoenix.ConnTest

  alias GroupStay.{Operations, Payments, Repo, Reservations}
  alias GroupStay.Operations.Operation

  @endpoint GroupStayWeb.Endpoint

  test "concurrent exact transfers move funding and advance each revision only once" do
    seed()

    move =
      transfer("source", "destination", 80, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    assert [result = %{"source_revision" => 3, "destination_revision" => 2}] =
             concurrently(List.duplicate(move, 6), @repo_name) |> Enum.uniq()

    assert Reservations.get_group("source").deposit_paid_cents == 20
    assert Reservations.get_group("destination").deposit_paid_cents == 80
    assert Reservations.ledger().cash_held_cents == 100
    assert Repo.aggregate(Operation, :count) == 4
    assert Operations.get_result(move["operation_id"]) == result
  end

  test "distinct concurrent transfers cannot overdraw a source" do
    seed()
    Operations.process(room_group("another"))

    results =
      concurrently(
        [transfer("source", "destination", 60), transfer("source", "another", 60)],
        @repo_name
      )

    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "transfer_exceeds_held_funding")) == 1
    assert Reservations.get_group("source").revision == 3
    assert Reservations.get_group("source").deposit_paid_cents == 40
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "the destination guard is atomic across transfers from different sources" do
    seed()
    Operations.process(room_group("another"))
    Operations.process(payment(%{"group_id" => "another", "amount_cents" => 100}))

    results =
      concurrently(
        [
          transfer("source", "destination", 60, %{"destination_expected_revision" => 1}),
          transfer("another", "destination", 60, %{"destination_expected_revision" => 1})
        ],
        @repo_name
      )

    assert Enum.count(results, &(&1["status"] == "applied")) == 1

    assert [%{"code" => "stale_revision", "group_id" => "destination", "actual_revision" => 2}] =
             Enum.filter(results, &(&1["status"] == "rejected"))

    assert Reservations.get_group("destination").deposit_paid_cents == 60
  end

  test "a transfer racing with a correction conserves payment dispositions" do
    seed()

    [move, reduction] =
      concurrently([transfer("source", "destination", 80), reduce_cash("p", 60)], @repo_name)

    assert reduction["status"] == "applied"
    assert {:ok, statement} = Payments.statement("p")
    assert statement.held_cents == 40
    assert statement.reduced_cents == 60
    assert Reservations.ledger().cash_held_cents == 40

    if move["status"] == "applied" do
      assert statement.held_by_group == [
               %{group_id: "destination", amount_cents: 20},
               %{group_id: "source", amount_cents: 20}
             ]

      assert Reservations.get_group("destination").revision == 3
    else
      assert move["code"] == "transfer_exceeds_held_funding"
      refute Map.has_key?(statement, :held_by_group)
      assert Reservations.get_group("destination").revision == 1
    end
  end

  test "audit failure rolls back both groups, allocations and participation flags and aborts the batch" do
    seed()
    move = transfer("source", "destination", 80, %{"operation_id" => "fault"})
    later = payment(%{"group_id" => "destination", "amount_cents" => 1})
    before = domain_snapshot()
    records = Repo.all(Operation)

    Repo.query!("""
    CREATE TRIGGER fail_transfer_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected transfer audit failure'); END
    """)

    try do
      assert_error_sent(500, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => [move, later]}))
      end)

      assert domain_snapshot() == before
      assert Repo.all(Operation) == records
    after
      Repo.query!("DROP TRIGGER fail_transfer_audit")
    end

    assert Operations.process(move)["status"] == "applied"
    assert Operations.process(later)["status"] == "applied"
  end

  test "transfers, corrections and statement participation survive restart with exact retries", %{
    repo_options: options
  } do
    seed()

    operations = [
      transfer("source", "destination", 80),
      reduce_cash("p", 20),
      cancel_rooms(["r1"], %{"group_id" => "destination", "refund_method" => "hotel_credit"})
    ]

    results = Enum.map(operations, &Operations.process/1)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = domain_snapshot()
    statement = Payments.statement("p")
    ledger = Reservations.ledger(~D[2026-11-01])
    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Enum.map(operations, &Operations.process/1) == results
    assert domain_snapshot() == before
    assert Payments.statement("p") == statement
    assert Reservations.ledger(~D[2026-11-01]) == ledger
    Operations.process(charge_back("p"))
    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)

    assert {:ok, %{held_by_group: [], charged_back_cents: 80, reduced_cents: 20}} =
             Payments.statement("p")
  end

  defp seed do
    for operation <- [
          room_group("source"),
          room_group("destination", [100]),
          payment(%{"group_id" => "source", "operation_id" => "p", "amount_cents" => 100})
        ] do
      assert Operations.process(operation)["status"] == "applied"
    end
  end
end
