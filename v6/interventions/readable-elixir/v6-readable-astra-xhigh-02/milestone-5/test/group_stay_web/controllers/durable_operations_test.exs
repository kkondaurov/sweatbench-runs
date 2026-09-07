defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.HotelCredit.{Application, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.{Group, Room}

  test "operation lookup returns only the original result and preserves identifiers", %{
    conn: conn
  } do
    assert conn |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    opening = open_group(%{"operation_id" => " OP-Ä ?# ", "internal_note" => "audit only"})
    [result] = submit(conn, [opening])
    assert read_operation(conn, opening) == %{"data" => result}
    assert result["operation_id"] == opening["operation_id"]
    refute Map.has_key?(result, "payload")
    refute Map.has_key?(result, "id")
    refute Map.has_key?(result, "type")
  end

  test "replaying a whole batch preserves every settlement, original revision and audit order", %{
    conn: conn
  } do
    operations = [
      open_group(%{"group_id" => "source"}),
      payment(%{"group_id" => "source", "expected_revision" => 1}),
      cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_group(),
      payment(%{"amount_cents" => 505, "expected_revision" => 1}),
      credit_payment(%{"amount_cents" => 600, "expected_revision" => 2}),
      reschedule(%{"expected_revision" => 3}),
      cancellation(%{"refund_method" => "hotel_credit", "expected_revision" => 4})
    ]

    results = submit(conn, operations)
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 1, 2, 3, 4, 5]
    assert List.last(results)["credit_issued_cents"] == 556
    before = snapshot()
    records = records()

    assert submit(conn, operations) === results
    assert submit(conn, operations) === results
    assert snapshot() == before
    assert records() == records
    assert Enum.map(records, & &1.payload) === operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) === results
    assert Enum.map(records, & &1.operation_id) == Enum.map(operations, & &1["operation_id"])

    for {operation, result} <- Enum.zip(operations, results) do
      assert read_operation(conn, operation) == %{"data" => result}
    end
  end

  test "duplicates and conflicts inside a batch leave later operations in order", %{conn: conn} do
    opening = open_group()
    payment = payment(%{"expected_revision" => 1})

    assert [opened, replayed_open, paid, replayed_payment, conflict, moved] =
             submit(conn, [
               opening,
               opening,
               payment,
               payment,
               Map.put(payment, "amount_cents", 2_000),
               reschedule(%{"expected_revision" => 2})
             ])

    assert opened == replayed_open
    assert paid == replayed_payment
    assert paid["revision"] == 2
    assert conflict == conflict(payment)
    assert moved["revision"] == 3
    assert Repo.aggregate(Operation, :count) == 3
    assert Repo.get!(Group, "group-81").deposit_paid_cents == 1_000
    assert read_operation(conn, payment) == %{"data" => paid}
  end

  test "missing-group and stale rejections stay fixed after domain state changes", %{conn: conn} do
    missing = payment(%{"expected_revision" => 1})

    [rejected, _, replayed, paid] =
      submit(conn, [missing, open_group(), missing, payment(%{"expected_revision" => 1})])

    assert rejected["code"] == "group_not_found"
    assert replayed == rejected
    assert paid["revision"] == 2

    stale = payment(%{"amount_cents" => -1, "expected_revision" => 1})
    [stale_result, moved] = submit(conn, [stale, reschedule(%{"expected_revision" => 2})])
    assert moved["revision"] == 3

    assert stale_result == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    before = snapshot()
    assert submit(conn, [missing, stale]) == [rejected, stale_result]
    assert submit(conn, [Map.put(stale, "expected_revision", 3)]) == [conflict(stale)]
    assert read_operation(conn, missing) == %{"data" => rejected}
    assert read_operation(conn, stale) == %{"data" => stale_result}
    assert snapshot() == before
  end

  test "insufficient-credit rejection is remembered even after the guest receives credit", %{
    conn: conn
  } do
    submit(conn, [open_group()])
    attempt = credit_payment()
    [rejected] = submit(conn, [attempt])
    assert rejected["code"] == "insufficient_credit"

    submit(conn, [
      open_group(%{"group_id" => "source"}),
      payment(%{"group_id" => "source"}),
      cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])

    before = snapshot()
    assert submit(conn, [attempt]) == [rejected]
    assert snapshot() == before
    assert [%{"revision" => 2}] = submit(conn, [credit_payment()])
  end

  test "object order is irrelevant at every depth and all submitted JSON is retained", %{
    conn: conn
  } do
    operation =
      open_group(%{
        "metadata" => %{
          "unknown" => [nil, true, false, "Ä", 9_007_199_254_740_993, 1.0],
          "nested" => [%{"z" => 1, "a" => %{"right" => 2, "left" => 3}}]
        }
      })

    body = %{"operations" => [operation]}
    ascending = ordered_json(body, :asc)
    descending = ordered_json(body, :desc)
    refute ascending == descending
    assert Jason.decode!(ascending) === Jason.decode!(descending)

    first = post_raw(conn, ascending) |> json_response(200)
    assert post_raw(conn, descending) |> json_response(200) == first
    assert [%Operation{payload: payload, result: result}] = records()
    assert payload === operation
    assert [result] == first["results"]
  end

  test "array order, JSON values, numeric types and optional fields participate in identity", %{
    conn: conn
  } do
    operation = open_group(%{"metadata" => %{"count" => 1, "items" => ["a", "b"]}})
    [original] = submit(conn, [operation])
    before = snapshot()
    records = records()

    variants = [
      Map.put(operation, "type", "cancel_group"),
      Map.put(operation, "group_id", "another"),
      Map.put(operation, "occurred_on", "2026-10-04"),
      Map.update!(operation, "rooms", &Enum.reverse/1),
      put_in(operation, ["metadata", "items"], ["b", "a"]),
      put_in(operation, ["metadata", "count"], 1.0),
      put_in(operation, ["metadata", "count"], "1"),
      Map.put(operation, "expected_revision", 1),
      Map.put(operation, "unknown", nil),
      Map.delete(operation, "metadata")
    ]

    assert submit(conn, variants) == List.duplicate(conflict(operation), length(variants))
    assert submit(conn, [operation]) == [original]
    assert snapshot() == before
    assert records() == records
  end

  test "invalid envelopes with usable IDs are audited, replayed and protected from correction", %{
    conn: conn
  } do
    invalid = [
      %{"operation_id" => "missing-type", "extra" => %{"data" => [1, nil]}},
      operation("unknown"),
      operation("unused", %{"type" => %{"invalid" => "type"}}),
      Map.delete(payment(), "group_id"),
      open_group(%{"occurred_on" => "bad"})
    ]

    results = submit(conn, invalid)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert Enum.map(records(), & &1.payload) === invalid

    assert Enum.map(records(), & &1.type) == [
             nil,
             "unknown",
             nil,
             "record_cash_payment",
             "open_group"
           ]

    assert submit(conn, invalid) == results

    corrected = Enum.map(invalid, &open_group(%{"operation_id" => &1["operation_id"]}))
    assert submit(conn, corrected) == Enum.map(invalid, &conflict/1)
    assert Repo.all(Group) == []
    assert Enum.map(records(), & &1.result) == results
  end

  test "values without a usable operation ID reject without reserving a retry key", %{conn: conn} do
    invalid =
      [nil, false, 10, "operation", [], %{}] ++
        Enum.map([nil, "", 1, true, [], %{}], &payment(%{"operation_id" => &1}))

    results = submit(conn, invalid)
    assert length(results) == length(invalid)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert records() == []
    assert submit(conn, invalid) == results
  end

  test "exact retries issue no domain reads or writes", %{conn: conn} do
    operations = [open_group(), payment(%{"expected_revision" => 99})]
    results = submit(conn, operations)
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:group_stay, :repo, :query],
        &__MODULE__.record_query/4,
        self()
      )

    try do
      assert submit(conn, operations) == results
    after
      :telemetry.detach(handler_id)
    end

    queries = recorded_queries()
    assert Enum.any?(queries, &String.contains?(&1, "operations"))

    refute Enum.any?(
             queries,
             &Regex.match?(
               ~r/groups|rooms|credit_lots|credit_applications|INSERT|UPDATE|DELETE/,
               &1
             )
           )
  end

  @doc false
  def record_query(_event, _measurements, %{query: query}, owner) do
    if self() == owner, do: send(owner, {:operation_query, query})
  end

  defp recorded_queries do
    receive do
      {:operation_query, query} -> [query | recorded_queries()]
    after
      0 -> []
    end
  end

  defp ordered_json(value, order) when is_map(value) do
    pairs = value |> Enum.sort_by(&elem(&1, 0), order)

    "{" <>
      Enum.map_join(pairs, ",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> ordered_json(value, order)
      end) <> "}"
  end

  defp ordered_json(value, order) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &ordered_json(&1, order)) <> "]"

  defp ordered_json(value, _order), do: Jason.encode!(value)

  defp submit(conn, operations),
    do:
      conn
      |> post_raw(Jason.encode!(%{"operations" => operations}))
      |> json_response(200)
      |> Map.fetch!("results")

  defp post_raw(conn, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", body)

  defp read_operation(conn, operation) do
    id = URI.encode(operation["operation_id"], &URI.char_unreserved?/1)
    conn |> get("/api/v1/operations/#{id}") |> json_response(200)
  end

  defp conflict(operation),
    do: %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => "operation_id_conflict"
    }

  defp records, do: Repo.all(from operation in Operation, order_by: operation.id)
  defp snapshot, do: {Repo.all(Group), Repo.all(Room), Repo.all(Lot), Repo.all(Application)}
end
