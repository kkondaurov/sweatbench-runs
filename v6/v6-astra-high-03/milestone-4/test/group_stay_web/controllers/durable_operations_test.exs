defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  defp opening(id, changes \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-03",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 1000},
          %{"room_id" => "b", "nightly_rate_cents" => 2000}
        ]
      },
      changes
    )
  end

  defp op(id, type, group, changes) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group,
        "occurred_on" => "2027-05-01"
      },
      changes
    )
  end

  defp batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp stored(conn, id) do
    conn
    |> get("/api/v1/operations/#{URI.encode(id)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp snapshot do
    {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation),
     Repo.all(from o in Operation, order_by: o.id)}
  end

  test "whole batches replay original results for every operation type after state changes", %{
    conn: conn
  } do
    operations = [
      opening("source"),
      op("pay", "record_cash_payment", "source", %{
        "amount_cents" => 1000,
        "expected_revision" => 1
      }),
      op("issue", "cancel_group", "source", %{
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }),
      opening("target"),
      op("redeem", "apply_hotel_credit", "target", %{
        "amount_cents" => 500,
        "expected_revision" => 1
      }),
      op("move", "reschedule_group", "target", %{
        "new_arrival_on" => "2027-07-01",
        "expected_revision" => 2
      }),
      op("restore", "cancel_group", "target", %{"expected_revision" => 3})
    ]

    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = snapshot()
    assert batch(conn, operations) == results
    assert batch(conn, Enum.reverse(operations)) == Enum.reverse(results)
    assert snapshot() == before

    for {operation, result} <- Enum.zip(operations, results) do
      assert stored(conn, operation["operation_id"]) == result
    end

    assert Repo.aggregate(Operation, :count) == 7
    assert Repo.aggregate(CreditLot, :count) == 1
    assert Repo.get_by!(CreditLot, source_operation_id: "issue").remaining_cents == 1100
  end

  test "duplicates and conflicts within a batch preserve order and the original record", %{
    conn: conn
  } do
    open = opening("group")
    payment = op("pay", "record_cash_payment", "group", %{"amount_cents" => 100})
    conflict = Map.put(payment, "amount_cents", 200)
    next = Map.put(conflict, "operation_id", "pay-next")

    assert [opened, first, retry, rejected, last] =
             batch(conn, [open, payment, payment, conflict, next])

    assert opened["revision"] == 1
    assert first == retry
    assert first["revision"] == 2

    assert rejected == %{
             "operation_id" => "pay",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert last["revision"] == 3
    assert Repo.get!(Group, "group").cash_paid_cents == 300
    assert stored(conn, "pay") == first
    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.operation_id) == ["open-group", "pay", "pay-next"]
    assert Enum.map(records, & &1.submission) == [open, payment, next]
  end

  test "rejections remain fixed when the group, revision, or available credit changes", %{
    conn: conn
  } do
    missing = op("missing", "record_cash_payment", "target", %{"amount_cents" => 10})
    [missing_result] = batch(conn, [missing])
    assert missing_result["code"] == "group_not_found"
    batch(conn, [opening("target")])
    stale = Map.merge(missing, %{"operation_id" => "stale", "expected_revision" => 0})
    insufficient = op("insufficient", "apply_hotel_credit", "target", %{"amount_cents" => 10})
    [stale_result, insufficient_result] = batch(conn, [stale, insufficient])
    assert stale_result["actual_revision"] == 1
    assert insufficient_result["code"] == "insufficient_credit"

    batch(conn, [
      opening("source"),
      op("fund", "record_cash_payment", "source", %{"amount_cents" => 100}),
      op("issue", "cancel_group", "source", %{"refund_method" => "hotel_credit"}),
      op("advance", "record_cash_payment", "target", %{"amount_cents" => 1})
    ])

    before = snapshot()

    assert batch(conn, [missing, stale, insufficient]) ==
             [missing_result, stale_result, insufficient_result]

    for corrected <- [
          Map.put(stale, "expected_revision", 2),
          Map.delete(stale, "expected_revision")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch(conn, [corrected])
    end

    assert snapshot() == before
    assert stored(conn, "stale") == stale_result
    assert stored(conn, "missing") == missing_result
    assert stored(conn, "insufficient") == insufficient_result
  end

  test "JSON object order is ignored recursively and complete submission values are significant",
       %{
         conn: conn
       } do
    operation = opening("json", %{"metadata" => %{"nested" => [%{"a" => 1, "b" => true}]}})
    [result] = batch(conn, [operation])

    # Submit actual JSON with every object's keys reversed, including room objects.
    reversed_json = fn reverse, value ->
      cond do
        is_map(value) ->
          "{" <>
            (value
             |> Enum.sort(:desc)
             |> Enum.map_join(",", fn {key, item} ->
               Jason.encode!(key) <> ":" <> reverse.(reverse, item)
             end)) <>
            "}"

        is_list(value) ->
          "[" <> Enum.map_join(value, ",", &reverse.(reverse, &1)) <> "]"

        true ->
          Jason.encode!(value)
      end
    end

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(
             "/api/v1/partner-batches",
             reversed_json.(reversed_json, %{"operations" => [operation]})
           )
           |> json_response(200) == %{"results" => [result]}

    before = snapshot()

    for changed <- [
          Map.put(operation, "rooms", Enum.reverse(operation["rooms"])),
          Map.put(operation, "metadata", %{"nested" => [%{"a" => 1.0, "b" => true}]}),
          Map.put(operation, "metadata", %{"nested" => [%{"a" => 1, "b" => "true"}]}),
          Map.put(operation, "extra", nil),
          Map.delete(operation, "metadata"),
          Map.put(operation, "type", "cancel_group"),
          Map.put(operation, "group_id", "another")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch(conn, [changed])
    end

    assert snapshot() == before
    record = Repo.get_by!(Operation, operation_id: operation["operation_id"])
    assert record.submission === operation
    assert stored(conn, operation["operation_id"]) == result
  end

  test "malformed identified submissions are audited; unidentifiable entries do not reserve IDs",
       %{
         conn: conn
       } do
    identified = [
      %{"operation_id" => "unknown", "type" => "future_type", "extra" => [1, nil, true]},
      %{"operation_id" => "missing-fields", "type" => "record_cash_payment"},
      %{"operation_id" => "missing-type"},
      %{"operation_id" => "invalid-type", "type" => %{"unusable" => [false]}}
    ]

    unidentified = [nil, [], 42, "bad", %{}, %{"operation_id" => ""}, %{"operation_id" => 12}]
    results = batch(conn, identified ++ unidentified)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(conn, identified) == Enum.take(results, length(identified))
    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.submission) == identified

    for {operation, result} <- Enum.zip(identified, results) do
      assert stored(conn, operation["operation_id"]) == result

      assert [%{"code" => "operation_id_conflict"}] =
               batch(conn, [opening("fixed", %{"operation_id" => operation["operation_id"]})])
    end

    assert conn |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    [result] = batch(conn, [opening("unicode", %{"operation_id" => " Op-É 001 "})])
    assert stored(conn, " Op-É 001 ") == result
  end
end
