defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, Room}

  test "a batch retry replays every operation's original result after later settlements", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01", "expected_revision" => 2}),
      operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 3}),
      open_operation(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 80,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", %{
        "group_id" => "target",
        "amount_cents" => 50,
        "expected_revision" => 2
      }),
      operation("cancel_group", %{
        "group_id" => "target",
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      })
    ]

    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4, 1, 2, 3, 4]
    before = snapshot()
    records = records()

    assert batch(conn, operations) == results
    assert batch(conn, Enum.reverse(operations)) == Enum.reverse(results)
    assert snapshot() == before
    assert records() == records

    for {operation, result} <- Enum.zip(operations, results) do
      assert stored_result(conn, operation["operation_id"]) == result
    end

    assert Enum.map(records, & &1.submission) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) == results
  end

  test "equivalent wire JSON ignores nested object key order and preserves all audit content", %{
    conn: conn
  } do
    opening =
      open_operation(%{
        "operation_id" => " OP-Ä 01 ",
        "extra" => %{
          "nested" => [%{"z" => nil, "a" => true}, [1, "1", false]],
          "large" => 9_223_372_036_854_775_808
        }
      })

    first_json = Jason.encode!(%{"operations" => [opening]})
    reordered_json = Jason.encode!(reorder(%{"operations" => [opening]}))
    refute first_json == reordered_json

    results = post_batch(conn, first_json)
    assert post_batch(conn, reordered_json) == results
    assert batch(conn, [opening, opening]) == results ++ results
    assert [%{submission: ^opening, type: "open_group"}] = records()
    assert stored_result(conn, opening["operation_id"]) == hd(results)
    assert Repo.get!(Group, opening["group_id"]).revision == 1
  end

  test "conflicts compare the complete payload and never replace the first record", %{conn: conn} do
    opening = open_operation(%{"extra" => %{"count" => 1, "items" => [true, nil, "x"]}})
    [result] = batch(conn, [opening])
    record = hd(records())
    before = snapshot()

    changed = [
      Map.put(opening, "rooms", Enum.reverse(opening["rooms"])),
      Map.put(opening, "expected_revision", 1),
      Map.put(opening, "refund_method", "cash"),
      Map.put(opening, "group_id", "different"),
      Map.put(opening, "type", "cancel_group"),
      Map.put(opening, "occurred_on", "2026-10-04"),
      Map.put(opening, "extra", nil),
      Map.delete(opening, "extra"),
      put_in(opening, ["extra", "count"], 1.0),
      put_in(opening, ["extra", "items"], [nil, true, "x"])
    ]

    for payload <- changed do
      assert batch(conn, [payload]) == [
               %{
                 "operation_id" => opening["operation_id"],
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
    end

    assert records() == [record]
    assert snapshot() == before
    assert stored_result(conn, opening["operation_id"]) == result
    assert batch(conn, [opening]) == [result]

    [conflict, payment, retry] =
      batch(conn, [
        hd(changed),
        operation("record_cash_payment", %{"amount_cents" => 1, "expected_revision" => 1}),
        opening
      ])

    assert conflict["code"] == "operation_id_conflict"
    assert payment["revision"] == 2
    assert retry == result
    assert hd(records()) == record
    assert length(records()) == 2
  end

  test "rejections remain final even when later operations make their submissions valid", %{
    conn: conn
  } do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    [rejected, opened, repeated, applied] =
      batch(conn, [
        payment,
        open_operation(),
        payment,
        Map.put(payment, "operation_id", unique_operation_id())
      ])

    assert rejected["code"] == "group_not_found"
    assert repeated == rejected
    assert opened["revision"] == 1
    assert applied["revision"] == 2
    assert stored_result(conn, payment["operation_id"]) == rejected
    assert Enum.map(records(), & &1.result) == [rejected, opened, applied]
  end

  test "stale retries preserve observed revisions and corrected expectations conflict", %{
    conn: conn
  } do
    batch(conn, [open_operation()])
    stale = operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 0})
    [original] = batch(conn, [stale])

    assert original == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    batch(conn, [
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group")
    ])

    before = snapshot()

    assert batch(conn, [stale]) == [original]

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(stale, "expected_revision", 3)])

    assert stored_result(conn, stale["operation_id"]) == original
    assert snapshot() == before
  end

  test "insufficient credit rolls back partial allocations but commits its rejection", %{
    conn: conn
  } do
    batch(conn, [
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_operation()
    ])

    application = operation("apply_hotel_credit", %{"amount_cents" => 111})
    before = snapshot()
    [rejected] = batch(conn, [application])
    assert rejected["code"] == "insufficient_credit"
    assert snapshot() == before
    assert stored_result(conn, application["operation_id"]) == rejected

    batch(conn, [
      open_operation(%{"group_id" => "another-source"}),
      operation("record_cash_payment", %{"group_id" => "another-source", "amount_cents" => 100}),
      operation("cancel_group", %{
        "group_id" => "another-source",
        "refund_method" => "hotel_credit"
      })
    ])

    [retry, fresh] =
      batch(conn, [application, Map.put(application, "operation_id", unique_operation_id())])

    assert retry == rejected
    assert fresh["status"] == "applied"
    assert fresh["revision"] == 2
  end

  test "invalid identified submissions are audited, while missing identifiers remain ordinary rejections",
       %{conn: conn} do
    submissions = [
      %{"operation_id" => "missing-type", "arbitrary" => [1, nil, %{"a" => "b"}]},
      %{"operation_id" => "unknown-type", "type" => "future_operation"},
      %{"operation_id" => "invalid-type", "type" => %{"value" => [true]}},
      Map.delete(open_operation(), "group_id")
    ]

    results = batch(conn, submissions)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(conn, submissions) == results
    assert Enum.map(records(), & &1.submission) == submissions
    assert Enum.map(records(), & &1.type) == [nil, "future_operation", nil, "open_group"]

    invalid = [
      nil,
      [],
      1,
      "operation",
      %{},
      %{"operation_id" => nil},
      %{"operation_id" => ""},
      %{"operation_id" => 42}
    ]

    assert Enum.all?(batch(conn, invalid), &(&1["code"] == "invalid_operation"))
    assert length(records()) == length(submissions)

    assert conn |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "replays and conflicts consult only the durable record", %{conn: conn} do
    opening = open_operation()
    stale = operation("cancel_group", %{"expected_revision" => %{"partner-value" => [1, nil]}})
    original = batch(conn, [opening, stale])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:group_stay, :repo, :query],
        &__MODULE__.capture_query/4,
        self()
      )

    try do
      assert batch(conn, [opening, stale]) == original

      assert [%{"code" => "operation_id_conflict"}] =
               batch(conn, [Map.put(stale, "expected_revision", 1)])
    after
      :telemetry.detach(handler)
    end

    queries = captured_queries()
    assert Enum.any?(queries, &String.contains?(&1, "FROM \"operations\""))

    refute Enum.any?(
             queries,
             &Regex.match?(
               ~r/\b(?:FROM|INTO|UPDATE) "(?:groups|rooms|credit_lots|credit_allocations)"/,
               &1
             )
           )

    refute Enum.any?(queries, &Regex.match?(~r/\b(?:INSERT|UPDATE|DELETE)\b/, &1))
  end

  @doc false
  def capture_query(_event, _measurements, metadata, recipient),
    do: send(recipient, {:operation_query, metadata.query})

  defp captured_queries do
    receive do
      {:operation_query, query} -> [query | captured_queries()]
    after
      0 -> []
    end
  end

  defp records, do: Repo.all(from operation in Operation, order_by: operation.id)

  defp snapshot,
    do: {Repo.all(Group), Repo.all(Room), Repo.all(CreditLot), Repo.all(CreditAllocation)}

  defp batch(conn, operations),
    do: post_batch(conn, Jason.encode!(%{operations: operations}))

  defp post_batch(conn, json) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", json)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp stored_result(conn, id) do
    conn
    |> recycle()
    |> get("/api/v1/operations/#{URI.encode(id)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp reorder(value) when is_map(value) do
    value
    |> Enum.sort(:desc)
    |> Enum.map(fn {key, value} -> {key, reorder(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp reorder(value) when is_list(value), do: Enum.map(value, &reorder/1)
  defp reorder(value), do: value
end
