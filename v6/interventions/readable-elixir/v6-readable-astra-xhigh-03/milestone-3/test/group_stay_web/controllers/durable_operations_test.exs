defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CashEntry, CreditAllocation, CreditLot, Group, OperationRecord}

  test "retries return original results in batch order after later revisions and cancellation", %{
    conn: conn
  } do
    opening = open_group()
    funding = payment(%{"expected_revision" => 1})
    moving = reschedule(%{"expected_revision" => 2})
    cancelling = cancellation(%{"expected_revision" => 3})

    assert [opened, paid, paid_again, moved, opened_again, cancelled, paid_after_cancel] =
             submit(conn, [opening, funding, funding, moving, opening, cancelling, funding])

    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert moved["revision"] == 3
    assert moved["new_arrival_on"] == "2027-01-02"
    assert moved["refundable_until"] == "2026-12-19"
    assert cancelled["revision"] == 4
    assert cancelled["refunded_cents"] == 5_000
    assert paid === paid_again
    assert paid === paid_after_cancel
    assert opened === opened_again

    before = snapshot()
    operations = [opening, funding, moving, cancelling]
    results = [opened, paid, moved, cancelled]
    assert submit(conn, operations) === results

    for {operation, result} <- Enum.zip(operations, results) do
      assert lookup(conn, operation["operation_id"]) === result
    end

    assert snapshot() == before
    assert Reservations.get_group("group-81").revision == 4
    assert Reservations.ledger().cash_refunded_cents == 5_000
    assert Repo.aggregate(CashEntry, :count) == 2
    assert Repo.aggregate(OperationRecord, :count) == 4
  end

  test "credit issuance, redemption and restoration each happen once", %{conn: conn} do
    source = [open_group(), payment(), cancellation(%{"refund_method" => "hotel_credit"})]
    [_, _, issued] = source_results = submit(conn, source)
    assert issued["credit_issued_cents"] == 5_500

    target = [
      open_group(%{"group_id" => "target"}),
      credit_application(%{"group_id" => "target", "amount_cents" => 5_000}),
      payment(%{"group_id" => "target", "amount_cents" => 5}),
      cancellation(%{"group_id" => "target", "refund_method" => "hotel_credit"})
    ]

    [_, _, _, settled] = target_results = submit(conn, target)
    assert settled["credit_issued_cents"] == 6
    before = snapshot()

    assert submit(conn, source ++ target ++ source ++ target) ===
             source_results ++ target_results ++ source_results ++ target_results

    assert snapshot() == before
    assert Repo.aggregate(CreditLot, :count) == 2
    assert Repo.aggregate(CreditAllocation, :count) == 1
    assert Reservations.get_group("target").revision == 4
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 5_506
    assert Reservations.ledger(~D[2026-11-01]).cash_converted_to_credit_cents == 5_005
  end

  test "missing-group and stale-revision rejections retain their original details", %{conn: conn} do
    missing = payment(%{"expected_revision" => 1})
    stale = payment(%{"expected_revision" => 1, "amount_cents" => -1})

    [missing_result, _, _, stale_result, _, missing_retry, stale_retry] =
      submit(conn, [
        missing,
        open_group(),
        payment(),
        stale,
        reschedule(),
        missing,
        stale
      ])

    assert missing_result["code"] == "group_not_found"
    assert missing_retry === missing_result

    assert stale_result == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert stale_retry === stale_result
    assert lookup(conn, stale["operation_id"]) === stale_result

    assert [conflict] = submit(conn, [Map.put(stale, "expected_revision", 3)])
    assert conflict == conflict_result(stale)
    assert lookup(conn, stale["operation_id"]) === stale_result
    assert Reservations.get_group("group-81").revision == 3
    assert Reservations.ledger().cash_held_cents == 5_000
  end

  test "insufficient credit and unavailable refunds stay rejected after they become valid", %{
    conn: conn
  } do
    submit(conn, [open_group(%{"group_id" => "target"})])
    spending = credit_application(%{"group_id" => "target"})
    [insufficient] = submit(conn, [spending])
    assert insufficient["code"] == "insufficient_credit"

    submit(conn, [open_group(), payment(), cancellation(%{"refund_method" => "hotel_credit"})])
    assert submit(conn, [spending]) === [insufficient]
    assert Reservations.get_group("target").credit_paid_cents == 0

    cancelling =
      cancellation(%{
        "group_id" => "target",
        "occurred_on" => "2026-11-27",
        "refund_method" => "hotel_credit"
      })

    [unavailable] = submit(conn, [cancelling])
    assert unavailable["code"] == "refund_method_not_available"
    submit(conn, [reschedule(%{"group_id" => "target"})])
    before = snapshot()
    assert submit(conn, [cancelling]) === [unavailable]
    assert snapshot() == before

    assert [%{"revision" => 3}, %{"revision" => 4}] =
             submit(conn, [
               Map.put(spending, "operation_id", "spend-with-new-id"),
               Map.put(cancelling, "operation_id", "cancel-with-new-id")
             ])
  end

  test "JSON object order is irrelevant at every depth and lookups preserve opaque IDs", %{
    conn: conn
  } do
    operation =
      open_group(%{
        "operation_id" => " Op-Ä /%?#+22 ",
        "metadata" => %{
          "z" => [1, true, nil, %{"b" => 2, "a" => ["literal", 1.0]}],
          "a" => %{"note" => "unrecognized content", "amount" => 9_223_372_036_854_775_808}
        }
      })

    [original] = submit(conn, [operation])
    before = snapshot()

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", "{\"operations\":[#{reordered_json(operation)}]}")

    assert json_response(response, 200) == %{"results" => [original]}
    assert lookup(conn, operation["operation_id"]) === original
    assert snapshot() == before
    assert Repo.one!(OperationRecord).submission === operation
  end

  test "conflicts account for all fields, value types and array positions", %{conn: conn} do
    operation = open_group(%{"metadata" => %{"values" => [1, 2], "optional" => nil}})
    [original] = submit(conn, [operation])
    before = snapshot()

    conflicting = [
      Map.put(operation, "group_id", "another-group"),
      Map.put(operation, "type", "unknown"),
      Map.delete(operation, "type"),
      Map.put(operation, "expected_revision", 1),
      Map.put(operation, "rooms", Enum.reverse(operation["rooms"])),
      Map.delete(operation, "metadata"),
      put_in(operation, ["metadata", "values"], [2, 1]),
      put_in(operation, ["metadata", "values"], [1.0, 2]),
      put_in(operation, ["metadata", "values"], ["1", 2]),
      put_in(operation, ["metadata", "optional"], false),
      update_in(operation, ["metadata"], &Map.delete(&1, "optional"))
    ]

    assert submit(conn, conflicting) ==
             List.duplicate(conflict_result(operation), length(conflicting))

    assert submit(conn, [operation]) === [original]
    assert lookup(conn, operation["operation_id"]) === original
    assert snapshot() == before
  end

  test "omitted defaults differ from explicit defaults and conflicts do not stop the batch", %{
    conn: conn
  } do
    submit(conn, [open_group(), payment()])
    operation = cancellation()

    [original, conflict, opened] =
      submit(conn, [
        operation,
        Map.put(operation, "refund_method", "cash"),
        open_group(%{"group_id" => "next"})
      ])

    assert original["refunded_cents"] == 5_000
    assert conflict == conflict_result(operation)
    assert opened["status"] == "applied"
    assert lookup(conn, operation["operation_id"]) === original
  end

  test "malformed operations with usable IDs are remembered with their complete submission", %{
    conn: conn
  } do
    operations = [
      %{"operation_id" => "unknown", "type" => "unknown", "extra" => [1, nil, true]},
      %{"operation_id" => "missing-type", "extra" => %{"value" => "keep me"}},
      %{"operation_id" => "invalid-type", "type" => %{"future" => ["operation"]}},
      %{"operation_id" => "missing-group", "type" => "record_cash_payment"},
      Map.delete(open_group(), "rooms"),
      open_group(%{"occurred_on" => "bad-date"})
    ]

    results = submit(conn, operations)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert submit(conn, operations) === results

    for {operation, result} <- Enum.zip(operations, results) do
      record = Repo.get_by!(OperationRecord, operation_id: operation["operation_id"])
      assert record.submission === operation
      assert record.result === result
      assert record.type == if(is_binary(operation["type"]), do: operation["type"])
      assert lookup(conn, operation["operation_id"]) === result

      assert submit(conn, [open_group(%{"operation_id" => operation["operation_id"]})]) ==
               [conflict_result(operation)]
    end

    assert Repo.all(Group) == []
    assert Repo.aggregate(OperationRecord, :count) == length(operations)
  end

  test "unusable IDs are rejected without reserving a key and missing lookups return 404", %{
    conn: conn
  } do
    operations =
      [nil, [], true, 42, %{}] ++
        Enum.map([nil, "", "  ", 42, %{}, ["id"]], &open_group(%{"operation_id" => &1}))

    assert Enum.all?(submit(conn, operations), &(&1["code"] == "invalid_operation"))
    assert Repo.all(OperationRecord) == []

    assert conn |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "audit order follows first commits, including rejections, regardless of dates and IDs", %{
    conn: conn
  } do
    opening = open_group(%{"operation_id" => "z-first", "occurred_on" => "2027-01-01"})
    rejected = payment(%{"operation_id" => "a-second", "amount_cents" => 0})
    funding = payment(%{"operation_id" => "m-third", "occurred_on" => "2026-11-01"})

    [opened, denied, _, _, paid] =
      submit(conn, [opening, rejected, opening, Map.put(opening, "guest_id", "conflict"), funding])

    records = Repo.all(from record in OperationRecord, order_by: record.id)
    assert Enum.map(records, & &1.operation_id) == ["z-first", "a-second", "m-third"]
    assert Enum.map(records, & &1.submission) === [opening, rejected, funding]
    assert Enum.map(records, & &1.result) === [opened, denied, paid]
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp lookup(conn, operation_id) do
    conn
    |> get("/api/v1/operations/" <> URI.encode(operation_id, &URI.char_unreserved?/1))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp conflict_result(operation) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => "operation_id_conflict"
    }
  end

  defp reordered_json(value) when is_map(value) do
    fields =
      value
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> reordered_json(value)
      end)

    "{" <> fields <> "}"
  end

  defp reordered_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &reordered_json/1) <> "]"

  defp reordered_json(value), do: Jason.encode!(value)

  defp snapshot do
    for schema <- [Group, CashEntry, CreditLot, CreditAllocation, OperationRecord] do
      Repo.all(from record in schema, order_by: ^schema.__schema__(:primary_key))
    end
  end
end
