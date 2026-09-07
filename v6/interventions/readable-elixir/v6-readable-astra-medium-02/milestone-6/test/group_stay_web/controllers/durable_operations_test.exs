defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  defp opening(id \\ "open") do
    %{
      "operation_id" => id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "b", "nightly_rate_cents" => 1000},
        %{"room_id" => "a", "nightly_rate_cents" => 2000}
      ]
    }
  end

  defp operation(id, type, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "occurred_on" => "2026-10-04",
        "group_id" => "group"
      },
      fields
    )
  end

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(path) do
    build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")
  end

  test "retries return original revisions and dates after later operations change the group" do
    open = opening()

    pay =
      operation("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})

    move = operation("move", "reschedule_group", %{"new_arrival_on" => "2027-07-01"})
    cancel = operation("cancel", "cancel_group")
    operations = [open, pay, move, cancel]
    results = batch(operations)
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    before = {read("groups/group"), read("ledger")}
    assert batch(operations ++ operations) == results ++ results
    assert {read("groups/group"), read("ledger")} == before

    for result <- results do
      assert read("operations/#{result["operation_id"]}") == result
    end

    for {operation, result} <- Enum.zip(operations, results) do
      assert GroupStay.Operations.execute(operation, fn ->
               flunk("retry evaluated domain state")
             end) ==
               result
    end

    assert Repo.aggregate(Record, :count) == 4

    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "remembered rejections survive changed state and conflict never replaces a record" do
    missing = operation("missing", "record_cash_payment", %{"amount_cents" => 100})
    [rejection, _] = batch([missing, opening()])
    assert rejection["code"] == "group_not_found"
    assert batch([missing]) == [rejection]

    stale =
      operation("stale", "record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 0})

    [original, _] =
      batch([stale, operation("pay", "record_cash_payment", %{"amount_cents" => 1})])

    assert original["actual_revision"] == 1
    assert batch([stale]) == [original]

    assert [%{"code" => "operation_id_conflict"}, %{"revision" => 3}] =
             batch([
               Map.put(stale, "expected_revision", 2),
               operation("later", "record_cash_payment", %{"amount_cents" => 1})
             ])

    assert read("operations/stale") == original
    assert Repo.get_by!(Record, operation_id: "stale").payload == stale
    assert Repo.aggregate(Record, :count) == 5
  end

  test "JSON key order is irrelevant at every depth, but arrays, types and extra values matter" do
    payload =
      Map.put(opening(), "metadata", %{"nested" => [%{"x" => 1, "y" => true}], "null" => nil})

    [result] = batch([payload])

    # Submit raw JSON with reversed object order, including room and metadata objects.
    reordered = """
    {"operations":[{"metadata":{"null":null,"nested":[{"y":true,"x":1}]},
    "rooms":[{"nightly_rate_cents":1000,"room_id":"b"},{"nightly_rate_cents":2000,"room_id":"a"}],
    "rate_plan":"flexible","departure_on":"2027-06-02","arrival_on":"2027-06-01",
    "property_id":"hotel","guest_id":"guest","group_id":"group",
    "occurred_on":"2026-10-03","type":"open_group","operation_id":"open"}]}
    """

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", reordered)
           |> json_response(200) == %{"results" => [result]}

    for changed <- [
          Map.put(payload, "rooms", Enum.reverse(payload["rooms"])),
          put_in(payload, ["metadata", "nested"], [%{"x" => "1", "y" => true}]),
          put_in(payload, ["metadata", "nested"], [%{"x" => 1.0, "y" => true}]),
          Map.delete(payload, "metadata"),
          Map.put(payload, "extra", nil),
          Map.put(payload, "type", "cancel_group")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert read("operations/open") == result
    assert Repo.aggregate(Record, :count) == 1
  end

  test "invalid envelopes with identifiers are audited completely in first commit order" do
    submissions = [
      %{"operation_id" => "z", "type" => "future", "extra" => [nil, true, %{"a" => 2}]},
      %{"operation_id" => "a", "type" => ["malformed"]},
      %{"operation_id" => "m"},
      opening()
    ]

    results = batch(submissions)
    assert Enum.map(results, & &1["status"]) == ["rejected", "rejected", "rejected", "applied"]
    assert batch(submissions) == results
    records = Repo.all(from r in Record, order_by: r.id)
    assert Enum.map(records, & &1.payload) === submissions
    assert Enum.map(records, & &1.result) == results
    assert Enum.map(records, & &1.type) == ["future", nil, nil, "open_group"]

    assert Enum.all?(
             batch([nil, [], %{}, %{"operation_id" => ""}, %{"operation_id" => 42}]),
             &(&1["code"] == "invalid_operation")
           )

    assert Repo.aggregate(Record, :count) == 4
  end

  test "retrying issuance, redemption and restoration never duplicates credit effects" do
    source = [
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100}),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    source_results = batch(source)
    assert List.last(source_results)["credit_issued_cents"] == 110
    assert batch(source) == source_results

    target = Map.put(opening("target-open"), "group_id", "target")

    apply =
      operation("apply", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100})

    restore = operation("restore", "cancel_group", %{"group_id" => "target"})
    results = batch([target, apply, apply, restore, restore])
    assert Enum.at(results, 1) == Enum.at(results, 2)
    assert Enum.at(results, 3) == Enum.at(results, 4)
    assert read("guests/guest/credit?on=2026-10-04")["available_cents"] == 110
    assert read("ledger?on=2026-10-04")["credit_liability_cents"] == 110
    assert Repo.aggregate(GroupStay.Reservations.CreditLot, :count) == 1
    assert Repo.aggregate(GroupStay.Reservations.CreditAllocation, :count) == 0
  end
end
