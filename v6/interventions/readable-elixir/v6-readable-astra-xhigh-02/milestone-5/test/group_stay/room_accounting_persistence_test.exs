defmodule GroupStay.RoomAccountingPersistenceTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import Plug.Conn
  import Phoenix.ConnTest

  alias GroupStay.{Operations, Payments, Repo, Reservations}
  alias GroupStay.Operations.Operation

  @endpoint GroupStayWeb.Endpoint

  test "concurrent exact reductions, room settlements and chargebacks commit once" do
    Operations.process(room_group())
    original = payment(%{"operation_id" => "p", "amount_cents" => 300})
    receipt = Operations.process(original)
    reduction = reduce_cash("p", 50, %{"expected_revision" => 2})
    assert [%{"revision" => 3}] = race(reduction)
    partial = cancel_rooms(["r2"], %{"expected_revision" => 3, "refund_method" => "hotel_credit"})
    assert [%{"revision" => 4, "credit_issued_cents" => 110}] = race(partial)
    chargeback = charge_back("p", %{"expected_revision" => 4})
    assert [%{"revision" => 5, "charged_back_cents" => 250}] = race(chargeback)
    assert Reservations.ledger(~D[2026-11-01]).cash_charged_back_cents == 250
    assert Reservations.ledger(~D[2026-11-01]).cash_reduced_cents == 50
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 0
    assert Repo.aggregate(Operation, :count) == 5
    assert Operations.process(original) == receipt

    for correction <- [reduction, partial, chargeback] do
      before = domain_snapshot()
      changed = Map.put(correction, "expected_revision", 5)
      assert Operations.process(changed)["code"] == "operation_id_conflict"
      assert domain_snapshot() == before
    end
  end

  test "distinct concurrent reductions cannot overdraw the same held cash" do
    Operations.process(room_group())
    Operations.process(payment(%{"operation_id" => "p", "amount_cents" => 100}))
    results = concurrently([reduce_cash("p", 60), reduce_cash("p", 60)], @repo_name)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reduction_exceeds_held_cash")) == 1
    assert {:ok, %{held_cents: 40, reduced_cents: 60}} = Payments.statement("p")
    assert Reservations.get_group("group-81").revision == 3
  end

  test "concurrent chargeback and reduction conserve the original payment" do
    Operations.process(room_group())
    Operations.process(payment(%{"operation_id" => "p", "amount_cents" => 100}))
    [reduction, chargeback] = concurrently([reduce_cash("p", 60), charge_back("p")], @repo_name)
    assert chargeback["status"] == "applied"
    assert {:ok, statement} = Payments.statement("p")
    assert statement.held_cents == 0
    assert statement.charged_back_cents + statement.reduced_cents == 100

    case reduction do
      %{"status" => "applied"} -> assert statement.charged_back_cents == 40
      %{"code" => "payment_not_reducible"} -> assert statement.charged_back_cents == 100
    end
  end

  test "an audit failure rolls back removed allocations, cash dispositions and credit clawbacks" do
    Operations.process(room_group())
    Operations.process(payment(%{"operation_id" => "p", "amount_cents" => 250}))
    Operations.process(cancel_rooms(["r1"], %{"refund_method" => "hotel_credit"}))
    operation = charge_back("p", %{"operation_id" => "fault"})
    later = payment(%{"amount_cents" => 1})
    before = domain_snapshot()
    records_before = Repo.all(Operation)

    Repo.query!("""
    CREATE TRIGGER fail_chargeback_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected chargeback audit failure'); END
    """)

    try do
      assert_error_sent(500, fn -> post_batch([operation, later]) end)
      assert domain_snapshot() == before
      assert Repo.all(Operation) == records_before
    after
      Repo.query!("DROP TRIGGER fail_chargeback_audit")
    end

    assert [result = %{"charged_back_cents" => 250}, %{"status" => "applied"}] =
             post_batch([operation, later]) |> json_response(200) |> Map.fetch!("results")

    assert Operations.process(operation) == result
    assert Reservations.ledger().cash_held_cents == 1
  end

  test "reconciliation, allocations, shortfalls and exact retries survive a repository restart",
       %{repo_options: options} do
    operations = [
      room_group(),
      payment(%{"operation_id" => "p", "amount_cents" => 250}),
      reduce_cash("p", 50),
      cancel_rooms(["r1"], %{"refund_method" => "hotel_credit"}),
      room_group("target"),
      credit_payment(%{"group_id" => "target", "amount_cents" => 110}),
      charge_back("p")
    ]

    results = Enum.map(operations, &Operations.process/1)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = domain_snapshot()
    {:ok, statement} = Payments.statement("p")
    ledger = Reservations.ledger(~D[2026-11-01])
    assert ledger.credit_shortfall_cents == 110
    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Enum.map(operations, &Operations.process/1) == results
    assert domain_snapshot() == before
    assert Payments.statement("p") == {:ok, statement}
    assert Reservations.ledger(~D[2026-11-01]) == ledger
    assert Operations.process(cancellation(%{"group_id" => "target"}))["status"] == "applied"
    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 0
  end

  defp race(operation), do: concurrently(List.duplicate(operation, 6), @repo_name) |> Enum.uniq()

  defp post_batch(operations),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
end
