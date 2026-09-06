defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.Operation
  import Ecto.Query

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 1000},
        %{"room_id" => "b", "nightly_rate_cents" => 1000}
      ]
    }
  end

  defp op(id, type, extra) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "group_id" => "g", "occurred_on" => "2027-02-01"},
      extra
    )
  end

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp stored(id) do
    build_conn()
    |> get("/api/v1/operations/#{id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "whole-batch retries replay all operation types and credit effects exactly once" do
    source = %{opening() | "group_id" => "source", "operation_id" => "source"}

    operations = [
      source,
      op("fund-source", "record_cash_payment", %{"group_id" => "source", "amount_cents" => 100}),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      opening(),
      op("cash", "record_cash_payment", %{"amount_cents" => 50, "expected_revision" => 1}),
      op("credit", "apply_hotel_credit", %{"amount_cents" => 60, "expected_revision" => 2}),
      op("move", "reschedule_group", %{"new_arrival_on" => "2027-07-01", "expected_revision" => 3}),
      op("cancel", "cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 4})
    ]

    original = batch(operations)
    assert Enum.all?(original, &(&1["status"] == "applied"))

    snapshot =
      {Reservations.get_group("g"), Reservations.ledger(~D[2027-02-01]),
       Reservations.guest_credit("guest", ~D[2027-02-01])}

    assert batch(operations) == original
    assert batch(operations) == original

    assert {Reservations.get_group("g"), Reservations.ledger(~D[2027-02-01]),
            Reservations.guest_credit("guest", ~D[2027-02-01])} == snapshot

    for result <- original, do: assert(stored(result["operation_id"]) == result)
    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.submission) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) == original
  end

  test "rejections and stale details remain frozen after state changes; conflicts never replace them" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 10})

    [rejected, _, paid] =
      batch([missing, opening(), op("pay", "record_cash_payment", %{"amount_cents" => 20})])

    assert rejected["code"] == "group_not_found"
    stale = op("stale", "cancel_group", %{"expected_revision" => 1})
    [original] = batch([stale])
    assert original["actual_revision"] == 2
    batch([op("pay-again", "record_cash_payment", %{"amount_cents" => 20})])
    assert batch([missing, stale]) == [rejected, original]

    assert [conflict, conflict2, next] =
             batch([
               Map.put(stale, "expected_revision", 3),
               Map.put(missing, "amount_cents", 11),
               op("next", "record_cash_payment", %{"amount_cents" => 10})
             ])

    assert conflict["code"] == "operation_id_conflict"
    assert conflict2["code"] == "operation_id_conflict"
    assert next["revision"] == 4
    assert stored("stale") == original
    assert stored("missing") == rejected
    assert stored("pay") == paid
  end

  test "JSON key order is ignored recursively; array order, extra fields and value types matter" do
    submission = Map.put(opening(), "metadata", %{"z" => [1, true, nil], "a" => %{"b" => "x"}})
    [original] = batch([submission])
    # Send different wire object order, including nested room objects.
    reordered = """
    {"operations":[{"metadata":{"a":{"b":"x"},"z":[1,true,null]},"rooms":[{"nightly_rate_cents":1000,"room_id":"a"},{"nightly_rate_cents":1000,"room_id":"b"}],"rate_plan":"flexible","departure_on":"2027-06-02","arrival_on":"2027-06-01","property_id":"hotel","guest_id":"guest","group_id":"g","occurred_on":"2027-01-01","type":"open_group","operation_id":"open"}]}
    """

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", reordered)
           |> json_response(200) == %{"results" => [original]}

    for changed <- [
          Map.delete(submission, "metadata"),
          Map.put(submission, "extra", nil),
          Map.put(submission, "rooms", Enum.reverse(submission["rooms"])),
          put_in(submission, ["metadata", "z"], [1.0, true, nil]),
          put_in(submission, ["metadata", "z"], [true, 1, nil])
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert stored("open") == original
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "same-batch duplicates replay and later retries do not need the group to exist" do
    missing = op("missing", "cancel_group", %{})
    payment = op("cash", "record_cash_payment", %{"amount_cents" => 20})

    [rejected, opened, retried_open, retried_rejection, paid, retried_payment] =
      batch([missing, opening(), opening(), missing, payment, payment])

    assert retried_open == opened
    assert retried_rejection == rejected
    assert retried_payment == paid
    assert Reservations.get_group("g").revision == 2
    # A retry must depend exclusively on its audit record.
    Repo.delete_all(GroupStay.Reservations.Group)
    assert batch([opening(), payment, missing]) == [opened, paid, rejected]
    assert Reservations.get_group("g") == nil
  end

  test "malformed operations with usable identifiers are audited and remembered" do
    operations = [
      %{"operation_id" => "unknown", "type" => "future", "extra" => [nil, %{"x" => 1}]},
      %{"operation_id" => "incomplete"},
      %{"operation_id" => "wrong-type", "type" => [1]}
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(operations) == results
    assert Enum.map(Repo.all(from o in Operation, order_by: o.id), & &1.submission) == operations

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(opening(), "operation_id", "incomplete")])

    assert Enum.all?(
             batch([nil, %{}, %{"operation_id" => ""}]),
             &(&1["code"] == "invalid_operation")
           )

    assert Repo.aggregate(Operation, :count) == 3

    assert build_conn() |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end
end
