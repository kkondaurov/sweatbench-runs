defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  import Ecto.Query

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    CreditEntitlement,
    Group,
    Operation,
    Repo,
    Room,
    RoomAllocation
  }

  test "retries replay every operation's exact original result after subsequent state changes" do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 5000, "expected_revision" => 1}),
      operation("reschedule_group", %{
        "new_arrival_on" => "2027-01-01",
        "expected_revision" => 2
      }),
      operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 3}),
      open_operation(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 500,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "target", "expected_revision" => 3})
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = snapshot()

    assert batch(operations) == results
    assert batch(Enum.reverse(operations)) == Enum.reverse(results)
    assert snapshot() == before

    for {op, result} <- Enum.zip(operations, results) do
      assert read_result(op["operation_id"]) == result
    end

    assert Repo.aggregate(CreditLot, :count) == 1
    assert GroupStay.ledger(~D[2026-11-26]).cash_refunded_cents == 100
    assert GroupStay.guest_credit("guest-22", ~D[2026-11-26]).available_cents == 5500
  end

  test "duplicate operations within a batch replay before later operations run" do
    opening = open_operation()
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    cancellation = operation("cancel_group", %{"expected_revision" => 2})

    assert [opened, reopened, paid, repaid, cancelled, late_paid] =
             batch([opening, opening, payment, payment, cancellation, payment])

    assert reopened == opened
    assert repaid == paid
    assert late_paid == paid
    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert cancelled["revision"] == 3
    assert Repo.aggregate(Operation, :count) == 3
    assert GroupStay.ledger().cash_refunded_cents == 100
  end

  test "JSON key order and whitespace are irrelevant at every object depth" do
    first =
      ~s({"operations":[{"operation_id":"ordered","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-b","nightly_rate_cents":15000},{"room_id":"room-a","nightly_rate_cents":17500}],"metadata":{"a":[{"x":1,"y":true}],"b":null}}]})

    retry =
      ~s({ "operations": [{ "metadata": {"b":null,"a":[{"y":true,"x":1}]}, "rooms":[{"nightly_rate_cents":15000,"room_id":"room-b"},{"nightly_rate_cents":17500,"room_id":"room-a"}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2026-10-03","type":"open_group","operation_id":"ordered"}] })

    results = raw_batch(first)
    assert [%{"status" => "applied"}] = results
    assert raw_batch(retry) == results
    assert Repo.aggregate(Operation, :count) == 1

    assert Repo.get_by!(Operation, operation_id: "ordered").payload ==
             hd(Jason.decode!(first)["operations"])
  end

  test "array order, nested values, number types, extra fields and omitted defaults are significant" do
    opening =
      open_operation(%{
        "metadata" => %{"nested" => [1, "1", true, nil], "amount" => 1}
      })

    [original] = batch([opening])
    before = snapshot()

    for changed <- [
          Map.put(opening, "rooms", Enum.reverse(opening["rooms"])),
          put_in(opening, ["metadata", "nested"], ["1", 1, true, nil]),
          put_in(opening, ["metadata", "amount"], 1.0),
          put_in(opening, ["metadata", "amount"], "1"),
          Map.put(opening, "extra", nil),
          Map.put(opening, "group_id", "elsewhere"),
          Map.put(opening, "type", "unknown"),
          Map.delete(opening, "type")
        ] do
      assert [conflict] = batch([changed])
      assert conflict == conflict_result(opening)
      assert read_result(opening["operation_id"]) == original
      assert snapshot() == before
    end

    cancellation = operation("cancel_group")
    [cancelled] = batch([cancellation])

    assert batch([Map.put(cancellation, "refund_method", "cash")]) ==
             [conflict_result(cancellation)]

    assert read_result(cancellation["operation_id"]) == cancelled
  end

  test "a missing-group rejection remains rejected after the group is opened" do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    [rejected, opened, replayed, paid] =
      batch([payment, open_operation(), payment, fresh(payment)])

    assert rejected["code"] == "group_not_found"
    assert replayed == rejected
    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert read_result(payment["operation_id"]) == rejected
    assert GroupStay.ledger().cash_held_cents == 100
  end

  test "insufficient credit is remembered after credit becomes available" do
    opening = open_operation()
    credit = operation("apply_hotel_credit", %{"amount_cents" => 100, "expected_revision" => 1})
    [_, rejected] = batch([opening, credit])
    assert rejected["code"] == "insufficient_credit"

    batch([
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])

    before = snapshot()
    assert batch([credit]) == [rejected]
    assert snapshot() == before
    assert [%{"revision" => 2}] = batch([fresh(credit)])
  end

  test "stale details are replayed verbatim and corrected revisions conflict" do
    batch([open_operation(), operation("record_cash_payment", %{"amount_cents" => 100})])
    stale = operation("cancel_group", %{"expected_revision" => 1})
    [original] = batch([stale])

    assert original == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    batch([operation("record_cash_payment", %{"amount_cents" => 100})])
    before = snapshot()
    assert batch([stale]) == [original]
    assert batch([Map.put(stale, "expected_revision", 3)]) == [conflict_result(stale)]
    assert read_result(stale["operation_id"]) == original
    assert snapshot() == before
  end

  test "all identifiable malformed submissions are retained without interfering with later operations" do
    malformed = [
      %{"operation_id" => "missing-type", "arbitrary" => [nil, 17, %{"x" => true}]},
      operation("unknown"),
      Map.put(operation("malformed"), "type", %{"unexpected" => [1, false]}),
      operation(nil),
      operation(42),
      operation("cancel_group", %{"group_id" => nil}),
      Map.delete(open_operation(), "rooms")
    ]

    results = batch(malformed)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(malformed) == results

    for {op, result} <- Enum.zip(malformed, results) do
      record = Repo.get_by!(Operation, operation_id: op["operation_id"])
      assert record.payload === op
      assert read_result(op["operation_id"]) == result
    end

    assert [%{"status" => "applied"}] = batch([open_operation()])
    assert Repo.aggregate(Operation, :count) == length(malformed) + 1
  end

  test "unidentifiable values reject without reserving an identifier" do
    malformed = [
      nil,
      [],
      42,
      true,
      "bad",
      %{},
      open_operation(%{"operation_id" => ""}),
      open_operation(%{"operation_id" => 42}),
      open_operation(%{"operation_id" => nil})
    ]

    results = batch(malformed)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert Repo.aggregate(Operation, :count) == 0
    assert [%{"status" => "applied"}] = batch([open_operation()])
  end

  test "audit records preserve full submissions, types and first commit order" do
    operations = [
      operation("record_cash_payment", %{"operation_id" => "z-first", "amount_cents" => 10}),
      open_operation(%{"operation_id" => "a-second", "metadata" => %{"raw" => [true, nil, 1.5]}}),
      operation("cancel_group", %{"operation_id" => "m-third", "occurred_on" => "2026-01-01"})
    ]

    results = batch(operations)
    records = Repo.all(from op in Operation, order_by: op.id)
    assert Enum.map(records, & &1.operation_id) == ~w(z-first a-second m-third)
    assert Enum.map(records, & &1.payload) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) == results

    assert batch(operations) == results

    assert batch([Map.put(hd(operations), "amount_cents", 11)]) == [
             conflict_result(hd(operations))
           ]

    assert Repo.all(from op in Operation, order_by: op.id) == records
  end

  test "lookup preserves partner identifiers and exposes only the original result" do
    id = " Operation + café-81 "
    [result] = batch([open_operation(%{"operation_id" => id, "private" => %{"note" => "audit"}})])
    assert read_result(id) == result

    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "an audit write exception returns 500, rolls back domain writes and stops the batch" do
    opening = open_operation()
    faulty = operation("record_cash_payment", %{"amount_cents" => 100})
    later = operation("cancel_group")
    fail_audit_write(faulty["operation_id"])

    assert_error_sent 500, fn -> batch([opening, faulty, later]) end

    assert GroupStay.get_group("group-81").revision == 1
    assert GroupStay.ledger().cash_held_cents == 0
    assert GroupStay.get_operation(opening["operation_id"])["status"] == "applied"
    assert GroupStay.get_operation(faulty["operation_id"]) == nil
    assert GroupStay.get_operation(later["operation_id"]) == nil

    Repo.query!("DROP TRIGGER fail_audit_write")

    assert [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}] =
             batch([opening, faulty, later])

    assert GroupStay.ledger().cash_refunded_cents == 100
  end

  test "an audit failure after credit settlement rolls back lots, funding and revision together" do
    batch([open_operation(), operation("record_cash_payment", %{"amount_cents" => 100})])
    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    before = snapshot()
    fail_audit_write(cancellation["operation_id"])

    assert_error_sent 500, fn -> batch([cancellation]) end
    assert snapshot() == before
    Repo.query!("DROP TRIGGER fail_audit_write")
    assert [%{"credit_issued_cents" => 110, "revision" => 3}] = batch([cancellation])
  end

  test "a domain exception rolls back a partial operation and is never remembered" do
    Repo.query!("""
    CREATE TRIGGER fail_second_room BEFORE INSERT ON rooms WHEN NEW.position = 1
    BEGIN SELECT RAISE(ABORT, 'injected room failure'); END
    """)

    opening = open_operation()
    later = operation("cancel_group")
    assert_error_sent 500, fn -> batch([opening, later]) end
    assert Repo.aggregate(Group, :count) == 0
    assert Repo.aggregate(Room, :count) == 0
    assert Repo.aggregate(Operation, :count) == 0

    Repo.query!("DROP TRIGGER fail_second_room")
    assert [%{"revision" => 1}, %{"revision" => 2}] = batch([opening, later])
  end

  test "exact retries read no current domain tables" do
    operations = [
      open_operation(),
      operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})
    ]

    results = batch(operations)
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")

    assert batch(operations) == results
    assert read_result(hd(operations)["operation_id"]) == hd(results)
  end

  test "replay preserves derived cancellation dates outside the input date range" do
    operations = [
      open_operation(),
      operation("reschedule_group", %{
        "occurred_on" => "-9999-01-01",
        "new_arrival_on" => "-9999-01-02"
      })
    ]

    [opened, moved] = batch(operations)
    assert moved["refundable_until"] == "-10000-12-19"
    assert batch(operations) == [opened, moved]
    assert read_result(List.last(operations)["operation_id"]) == moved
  end

  defp fail_audit_write(operation_id) do
    # Bind the identifier into a temporary table; trigger SQL never interpolates input.
    Repo.query!("CREATE TABLE failing_operation (operation_id TEXT)")
    Repo.query!("INSERT INTO failing_operation VALUES (?)", [operation_id])

    Repo.query!("""
    CREATE TRIGGER fail_audit_write BEFORE INSERT ON operations
    WHEN NEW.operation_id IN (SELECT operation_id FROM failing_operation)
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)
  end

  defp fresh(op), do: Map.put(op, "operation_id", unique_operation_id())

  defp conflict_result(op) do
    %{
      "operation_id" => op["operation_id"],
      "status" => "rejected",
      "code" => "operation_id_conflict"
    }
  end

  defp batch(operations), do: raw_batch(Jason.encode!(%{operations: operations}))

  defp raw_batch(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read_result(id) do
    build_conn()
    |> get("/api/v1/operations/" <> URI.encode(id, &URI.char_unreserved?/1))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp snapshot do
    for schema <- [
          Group,
          Room,
          CreditLot,
          CreditAllocation,
          CreditEntitlement,
          RoomAllocation,
          Operation
        ] do
      Repo.all(schema) |> Enum.sort()
    end
  end
end
