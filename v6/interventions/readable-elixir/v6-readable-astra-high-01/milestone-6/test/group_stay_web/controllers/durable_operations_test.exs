defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures
  import Ecto.Query

  alias GroupStay.{Credits, Repo, Reservations}
  alias GroupStay.Operations.Record
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Reservations.Group

  test "retries of every operation return original results after subsequent changes", %{
    conn: conn
  } do
    operations = [
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 500}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_operation(),
      operation("apply_hotel_credit", %{"amount_cents" => 400, "expected_revision" => 1}),
      operation("record_cash_payment", %{"amount_cents" => 105, "expected_revision" => 2}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-03-01", "expected_revision" => 3}),
      operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 4})
    ]

    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert List.last(results)["credit_issued_cents"] == 116
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 666
    before = snapshot()

    assert batch(conn, operations) == results
    assert batch(conn, Enum.reverse(operations)) == Enum.reverse(results)
    assert snapshot() == before

    for {operation, result} <- Enum.zip(operations, results) do
      assert read_result(conn, operation["operation_id"]) == result
    end
  end

  test "a duplicate within a batch does not advance the revision seen by later operations", %{
    conn: conn
  } do
    opening = open_operation()
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    later = operation("record_cash_payment", %{"amount_cents" => 50, "expected_revision" => 2})

    assert [first, first, paid, paid, %{"revision" => 3}] =
             batch(conn, [opening, opening, payment, payment, later])

    assert first["revision"] == 1
    assert paid["revision"] == 2
    assert Reservations.ledger().cash_held_cents == 150
    assert Repo.aggregate(Record, :count) == 3
  end

  test "rejections stay fixed when a missing group appears and when revisions advance", %{
    conn: conn
  } do
    missing = operation("record_cash_payment", %{"amount_cents" => 100})
    [rejected] = batch(conn, [missing])
    assert rejected["code"] == "group_not_found"
    batch(conn, [open_operation()])
    assert batch(conn, [missing]) == [rejected]

    stale = operation("reschedule_group", %{"expected_revision" => 0, "new_arrival_on" => "bad"})
    [rejected] = batch(conn, [stale])
    assert rejected["actual_revision"] == 1
    batch(conn, [operation("record_cash_payment", %{"amount_cents" => 50})])
    before = snapshot()
    assert batch(conn, [stale]) == [rejected]
    assert read_result(conn, stale["operation_id"]) == rejected

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(stale, "expected_revision", 2)])

    assert snapshot() == before
  end

  test "object key order is irrelevant at every depth; array order and values matter", %{
    conn: conn
  } do
    opening = open_operation(%{"metadata" => %{"b" => [%{"y" => nil, "x" => true}], "a" => 1}})
    [result] = batch(conn, [opening])

    # Encode the same object in reverse key order, including nested room objects.
    raw = "{\"operations\":[" <> encode_reordered(opening) <> "]}"
    assert conn |> post_json(raw) |> json_response(200) == %{"results" => [result]}

    variants = [
      Map.update!(opening, "rooms", &Enum.reverse/1),
      Map.put(opening, "metadata", %{"b" => [%{"y" => nil, "x" => true}], "a" => 1.0}),
      Map.delete(opening, "metadata"),
      Map.put(opening, "extra", nil),
      Map.put(opening, "type", "cancel_group"),
      Map.put(opening, "group_id", "another-group")
    ]

    before = snapshot()
    assert Enum.all?(batch(conn, variants), &(&1["code"] == "operation_id_conflict"))
    assert snapshot() == before
    assert read_result(conn, opening["operation_id"]) == result
  end

  test "audit retains complete rejected submissions in first commit order", %{conn: conn} do
    invalid = [
      %{"operation_id" => "z", "type" => "unknown", "extra" => [%{"a" => false}, nil]},
      %{"operation_id" => "a", "type" => %{"bad" => [1, 2]}, "amount_cents" => 1.5},
      %{"operation_id" => "m", "extra" => "no type or group"}
    ]

    results = batch(conn, invalid)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(conn, Enum.reverse(invalid)) == Enum.reverse(results)

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(hd(invalid), "extra", [])])

    records = Repo.all(from record in Record, order_by: record.id)
    assert Enum.map(records, & &1.operation_id) == ["z", "a", "m"]
    assert Enum.map(records, & &1.payload) === invalid
    assert Enum.map(records, & &1.type) == ["unknown", nil, nil]
    assert Enum.map(records, & &1.result) == results

    for {operation, result} <- Enum.zip(invalid, results) do
      assert read_result(conn, operation["operation_id"]) == result
    end
  end

  test "unidentifiable operations reject independently without reserving an identifier", %{
    conn: conn
  } do
    invalid = [nil, [], 42, %{}, %{"operation_id" => ""}, %{"operation_id" => 1}]
    results = batch(conn, invalid ++ [open_operation()])
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"
    assert Repo.aggregate(Record, :count) == 1
  end

  test "operation lookup returns only the result and preserves partner identifiers", %{conn: conn} do
    id = " Op-é 001 "
    [result] = batch(conn, [open_operation(%{"operation_id" => id})])
    assert read_result(conn, id) == result

    assert conn |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "replaying a stale result preserves arbitrary submitted revision values", %{conn: conn} do
    batch(conn, [open_operation()])
    expected = %{"new_arrival_on" => "not-a-date", "nested" => [nil, false, 1.5]}
    attempt = operation("cancel_group", %{"expected_revision" => expected})
    [result] = batch(conn, [attempt])
    assert result["code"] == "stale_revision"
    assert result["expected_revision"] === expected
    batch(conn, [operation("cancel_group")])

    assert batch(conn, [attempt]) === [result]
    assert read_result(conn, attempt["operation_id"]) === result
  end

  defp snapshot do
    {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation),
     Repo.all(from record in Record, order_by: record.id)}
  end

  defp batch(conn, operations) do
    conn
    |> post_json(Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp read_result(conn, id) do
    conn
    |> get("/api/v1/operations/#{URI.encode(id)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp encode_reordered(value) when is_map(value) do
    entries =
      value
      |> Enum.sort(:desc)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> encode_reordered(value)
      end)

    "{" <> entries <> "}"
  end

  defp encode_reordered(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &encode_reordered/1) <> "]"

  defp encode_reordered(value), do: Jason.encode!(value)
end
