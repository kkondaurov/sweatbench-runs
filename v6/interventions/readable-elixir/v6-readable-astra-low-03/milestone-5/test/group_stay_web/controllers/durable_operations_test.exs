defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Record

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10000},
        %{"room_id" => "b", "nightly_rate_cents" => 20000}
      ]
    }
  end

  defp payment(id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "record_cash_payment",
        "occurred_on" => "2027-02-01",
        "group_id" => "group",
        "amount_cents" => 100,
        "expected_revision" => 1
      },
      overrides
    )
  end

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "exact retries replay original revisions and stale details before domain reads" do
    [opened, paid, stale] = batch([opening(), payment("pay"), payment("stale")])
    assert stale["actual_revision"] == 2
    assert [%{"revision" => 3}] = batch([payment("next", %{"expected_revision" => 2})])
    assert batch([opening(), payment("pay"), payment("stale")]) == [opened, paid, stale]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([payment("stale", %{"expected_revision" => 3})])

    assert Reservations.get_group("group").cash_paid_cents == 200
    assert Repo.aggregate(Record, :count) == 4

    assert build_conn() |> get("/api/v1/operations/stale") |> json_response(200) == %{
             "data" => stale
           }

    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "rejections remain rejected after state changes, and audit retains complete submissions in order" do
    rejected_op = payment("missing")

    invalid = %{
      "operation_id" => "unknown",
      "type" => "future",
      "extra" => [nil, true, %{"x" => 1}]
    }

    [rejected, invalid_result, opened] = batch([rejected_op, invalid, opening()])
    assert rejected["code"] == "group_not_found"
    assert batch([rejected_op, invalid, opening()]) == [rejected, invalid_result, opened]
    records = Repo.all(from r in Record, order_by: r.id)
    assert Enum.map(records, & &1.operation_id) == ["missing", "unknown", "open"]
    assert Enum.map(records, & &1.submission) == [rejected_op, invalid, opening()]

    assert Enum.map(records, & &1.operation_type) == [
             "record_cash_payment",
             "future",
             "open_group"
           ]
  end

  test "object ordering is irrelevant but array order, extra fields and value types conflict" do
    op = opening()
    [original] = batch([op])
    # Send raw JSON in reverse key order, including reversed room-object keys.
    rooms =
      Enum.map(op["rooms"], fn room ->
        ~s({"nightly_rate_cents":#{room["nightly_rate_cents"]},"room_id":#{Jason.encode!(room["room_id"])}})
      end)

    fields =
      op
      |> Map.delete("rooms")
      |> Enum.sort(:desc)
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> Jason.encode!(v) end)

    json =
      "{\"operations\":[{" <>
        Enum.join(fields ++ ["\"rooms\":[" <> Enum.join(rooms, ",") <> "]"], ",") <> "}]}"

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", json)
           |> json_response(200) == %{"results" => [original]}

    for changed <- [
          Map.put(op, "rooms", Enum.reverse(op["rooms"])),
          Map.put(op, "extra", nil),
          put_in(op, ["rooms", Access.at(0), "nightly_rate_cents"], 10000.0)
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert Operations.get_result("open") == original
  end

  test "credit issuance, redemption, restoration and rescheduling replay without new effects" do
    cancel = %{
      "operation_id" => "issue",
      "type" => "cancel_group",
      "group_id" => "group",
      "occurred_on" => "2027-02-01",
      "refund_method" => "hotel_credit"
    }

    target = Map.merge(opening(), %{"operation_id" => "target", "group_id" => "target"})

    redeem = %{
      "operation_id" => "redeem",
      "type" => "apply_hotel_credit",
      "group_id" => "target",
      "occurred_on" => "2027-02-01",
      "amount_cents" => 110
    }

    move = %{
      "operation_id" => "move",
      "type" => "reschedule_group",
      "group_id" => "target",
      "occurred_on" => "2027-02-01",
      "new_arrival_on" => "2027-07-01"
    }

    restore = Map.merge(cancel, %{"operation_id" => "restore", "group_id" => "target"})
    ops = [opening(), payment("pay"), cancel, target, redeem, move, restore]
    results = batch(ops)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    ledger = Reservations.ledger(~D[2027-02-01])
    credit = GroupStay.Credit.available("guest", ~D[2027-02-01])
    assert credit.available_cents == 110
    assert batch(ops ++ ops) == results ++ results
    assert Reservations.ledger(~D[2027-02-01]) == ledger
    assert GroupStay.Credit.available("guest", ~D[2027-02-01]) == credit
    assert Repo.aggregate(Record, :count) == length(ops)
  end

  test "handled rejection rolls back domain writes while remembering the rejection" do
    [original] = batch([opening()])
    submission = %{"operation_id" => "reject", "type" => "test"}

    result =
      Operations.execute(submission, fn ->
        Repo.delete!(Reservations.get_group("group"))
        Operations.reject(%{code: "test_rejection"})
      end)

    assert result["code"] == "test_rejection"
    assert Reservations.get_group("group").revision == original["revision"]
    assert Operations.execute(submission, fn -> flunk("retry ran domain code") end) == result
  end

  test "unexpected faults abort the batch, undo writes and leave no audit record" do
    # A database trigger injects a failure after domain work but before recording
    # the outcome, exercising atomicity at the last possible write.
    Repo.query!("""
    CREATE TEMP TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    assert_raise Exqlite.Error, fn ->
      batch([opening(), payment("fault"), payment("later")])
    end

    assert Reservations.get_group("group").revision == 1
    assert Operations.get_result("open")
    assert Operations.get_result("fault") == nil
    assert Operations.get_result("later") == nil
    Repo.query!("DROP TRIGGER fail_audit")
    assert [%{"revision" => 2}] = batch([payment("fault")])
  end
end
