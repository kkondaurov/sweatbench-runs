defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Operations.Record

  defp operation(id, type, fields) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-02-01"
      },
      fields
    )
  end

  defp open(id \\ "open") do
    operation(id, "open_group", %{
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10000},
        %{"room_id" => "b", "nightly_rate_cents" => 20000}
      ],
      "metadata" => %{"nested" => [%{"a" => true, "b" => nil}], "number" => 1.5}
    })
  end

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp stored(id) do
    build_conn() |> get("/api/v1/operations/" <> id) |> json_response(200) |> Map.fetch!("data")
  end

  test "every operation replays its original result after later revisions and settlement" do
    operations = [
      open(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
      operation("move", "reschedule_group", %{"new_arrival_on" => "2027-05-01"}),
      operation("cancel", "cancel_group", %{"refund_method" => "hotel_credit"}),
      Map.put(open("target-open"), "group_id", "target"),
      operation("credit", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      operation("target-cancel", "cancel_group", %{"group_id" => "target"})
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    before =
      {Reservations.get_group("group"), Reservations.get_group("target"),
       Reservations.ledger(~D[2027-02-01])}

    assert batch(operations) == results
    assert batch(operations ++ operations) == results ++ results

    assert {Reservations.get_group("group"), Reservations.get_group("target"),
            Reservations.ledger(~D[2027-02-01])} == before

    records = Repo.all(from r in Record, order_by: r.id)
    assert Enum.map(records, & &1.submission) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) == results

    for result <- results, do: assert(stored(result["operation_id"]) == result)
  end

  test "rejections stay fixed, corrected revisions conflict, and later operations continue" do
    missing = operation("missing", "record_cash_payment", %{"amount_cents" => 100})
    [rejected, _] = batch([missing, open()])
    assert rejected["code"] == "group_not_found"
    assert batch([missing]) == [rejected]

    stale = operation("stale", "cancel_group", %{"expected_revision" => 0})

    [original, _] =
      batch([stale, operation("pay", "record_cash_payment", %{"amount_cents" => 100})])

    assert original["actual_revision"] == 1
    assert batch([stale]) == [original]

    assert [conflict, applied] =
             batch([
               Map.put(stale, "expected_revision", 2),
               operation("cancel", "cancel_group", %{"expected_revision" => 2})
             ])

    assert conflict["code"] == "operation_id_conflict"
    assert applied["revision"] == 3
    assert stored("stale") == original
    assert batch([stale]) == [original]

    invalid = %{"operation_id" => "invalid", "type" => "future", "complete" => [1, nil, true]}
    assert [first] = batch([invalid])
    assert first["code"] == "invalid_operation"
    assert batch([invalid]) == [first]
    assert Repo.get_by!(Record, operation_id: "invalid").submission == invalid

    assert build_conn() |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "JSON key order is irrelevant but nested values, arrays and omitted fields matter" do
    submitted = open()
    [original] = batch([submitted])

    # Send actual JSON in a different key order, including nested room objects.
    reordered =
      submitted
      |> Enum.sort(:desc)
      |> Enum.map(fn
        {"rooms", rooms} ->
          {"rooms",
           Enum.map(rooms, fn room -> Jason.OrderedObject.new(Enum.sort(room, :desc)) end)}

        pair ->
          pair
      end)
      |> Jason.OrderedObject.new()

    response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => [reordered]}))
      |> json_response(200)

    assert response["results"] == [original]

    for changed <- [
          Map.update!(submitted, "rooms", &Enum.reverse/1),
          put_in(submitted, ["metadata", "number"], 2),
          Map.put(submitted, "unused", nil),
          Map.put(submitted, "type", "cancel_group")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert stored("open") == original
    assert Repo.aggregate(Record, :count) == 1
  end

  test "an exact retry never consults the current reservation tables" do
    submitted = open()
    [original] = batch([submitted])
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert batch([submitted]) == [original]
    assert stored("open") == original
  end

  test "unidentifiable operations reject independently without audit records" do
    assert Enum.all?(
             batch([nil, 1, %{}, %{"operation_id" => ""}]),
             &(&1["code"] == "invalid_operation")
           )

    assert Repo.aggregate(Record, :count) == 0
  end
end
