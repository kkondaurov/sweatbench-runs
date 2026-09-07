defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, OperationRecord, Room}

  test "replaying a whole batch preserves every original result and all accounting", %{conn: conn} do
    operations = [
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-06-01", "expected_revision" => 2}),
      operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 3}),
      open_group(%{"group_id" => "next"}),
      operation("apply_hotel_credit", %{
        "group_id" => "next",
        "amount_cents" => 80,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", %{"group_id" => "next", "amount_cents" => 50}),
      operation("cancel_group", %{
        "group_id" => "next",
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      })
    ]

    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = snapshot()

    assert batch(conn, operations) == results
    assert batch(conn, operations ++ operations) == results ++ results
    assert snapshot() == before

    for {operation, result} <- Enum.zip(operations, results) do
      assert lookup(conn, operation["operation_id"]) == %{"data" => result}
    end

    records = Repo.all(from record in OperationRecord, order_by: record.id)
    assert Enum.map(records, & &1.payload) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) == results
  end

  test "same-batch duplicates apply once and conflicts do not stop later operations", %{
    conn: conn
  } do
    open = open_group()
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    changed = Map.put(payment, "amount_cents", 200)
    cancel = operation("cancel_group")

    assert [opened, paid, retried, conflict, cancelled] =
             batch(conn, [open, payment, payment, changed, cancel])

    assert opened["revision"] == 1
    assert paid == retried

    assert conflict == %{
             "operation_id" => payment["operation_id"],
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert cancelled["refunded_cents"] == 100
    assert cancelled["revision"] == 3
    assert lookup(conn, payment["operation_id"]) == %{"data" => paid}
    assert Repo.aggregate(OperationRecord, :count) == 3
  end

  test "object order is irrelevant at every depth and complete JSON values remain significant", %{
    conn: conn
  } do
    original =
      open_group(%{
        "metadata" => %{"nested" => [%{"a" => 1, "b" => nil}], "flag" => true}
      })

    [result] = batch(conn, [original])
    before = snapshot()

    reversed_json = "{\"operations\":[" <> reverse_object_keys(original) <> "]}"
    assert post_json(conn, reversed_json) == [result]

    for changed <- [
          Map.update!(original, "rooms", &Enum.reverse/1),
          Map.put(original, "group_id", "another"),
          Map.put(original, "type", "cancel_group"),
          Map.put(original, "extra", nil),
          Map.delete(original, "metadata"),
          put_in(original, ["metadata", "nested"], [%{"a" => 1.0, "b" => nil}]),
          put_in(original, ["metadata", "flag"], "true")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch(conn, [changed])
    end

    assert batch(conn, [original]) == [result]
    assert snapshot() == before
  end

  test "rejections remain original after their cause is resolved", %{conn: conn} do
    missing = operation("record_cash_payment", %{"amount_cents" => 100})
    [rejected] = batch(conn, [missing])
    assert rejected["code"] == "group_not_found"
    batch(conn, [open_group()])

    assert batch(conn, [missing]) == [rejected]
    assert lookup(conn, missing["operation_id"]) == %{"data" => rejected}
    assert Repo.get!(Group, "group-81").revision == 1
    assert Repo.get!(Group, "group-81").deposit_paid_cents == 0

    assert [%{"status" => "applied", "revision" => 2}] =
             batch(conn, [Map.put(missing, "operation_id", unique_operation_id())])
  end

  test "stale details are replayed exactly and a corrected revision conflicts", %{conn: conn} do
    batch(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 100})])
    stale = operation("cancel_group", %{"expected_revision" => 1})
    [rejected] = batch(conn, [stale])
    assert rejected["actual_revision"] == 2
    assert rejected["expected_revision"] == 1
    batch(conn, [operation("record_cash_payment", %{"amount_cents" => 100})])

    assert batch(conn, [stale]) == [rejected]
    assert lookup(conn, stale["operation_id"]) == %{"data" => rejected}

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(stale, "expected_revision", 3)])

    assert Repo.get!(Group, "group-81").revision == 3

    # Partner values inside stale details are JSON too, including arbitrary keys.
    malformed_revision =
      operation("cancel_group", %{
        "expected_revision" => %{"partner-key-never-an-atom" => [1, nil, true]}
      })

    [result] = batch(conn, [malformed_revision])
    assert batch(conn, [malformed_revision]) == [result]
    assert result["expected_revision"] == malformed_revision["expected_revision"]
  end

  test "invalid envelopes with identifiers are audited before validation", %{conn: conn} do
    for type <- ["unknown", nil, 12, %{"unexpected" => true}, ["cancel_group"]] do
      invalid = %{"operation_id" => unique_operation_id(), "type" => type, "extra" => [nil, 3]}
      [result] = batch(conn, [invalid])
      assert result["code"] == "invalid_operation"
      assert batch(conn, [invalid]) == [result]
      assert lookup(conn, invalid["operation_id"]) == %{"data" => result}
      record = Repo.get_by!(OperationRecord, operation_id: invalid["operation_id"])
      assert record.payload == invalid
      assert record.type == if(is_binary(type), do: type)

      assert [%{"code" => "operation_id_conflict"}] =
               batch(conn, [open_group(%{"operation_id" => invalid["operation_id"]})])
    end

    for missing <- ["type", "group_id", "occurred_on", "rooms"] do
      invalid = Map.delete(open_group(), missing)
      [result] = batch(conn, [invalid])
      assert result["code"] == "invalid_operation"
      assert batch(conn, [invalid]) == [result]

      assert Repo.get_by!(OperationRecord, operation_id: invalid["operation_id"]).payload ==
               invalid
    end

    assert Repo.all(Group) == []
  end

  test "unusable identifiers remain invalid and cannot create audit records", %{conn: conn} do
    invalid = [
      nil,
      [],
      12,
      %{},
      open_group(%{"operation_id" => ""}),
      open_group(%{"operation_id" => 17}),
      open_group(%{"operation_id" => nil})
    ]

    assert Enum.all?(batch(conn, invalid), &(&1["code"] == "invalid_operation"))
    assert Repo.all(OperationRecord) == []
    assert lookup(conn, "missing", 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "lookup preserves partner identifiers and exposes only the stored result", %{conn: conn} do
    operation = open_group(%{"operation_id" => " Op-Ä 01 ", "private_metadata" => "audit only"})
    [result] = batch(conn, [operation])
    assert lookup(conn, operation["operation_id"]) == %{"data" => result}
    refute Map.has_key?(result, "payload")
    refute Map.has_key?(result, "id")
    refute Map.has_key?(result, "private_metadata")
  end

  defp batch(conn, operations),
    do: post_json(conn, Jason.encode!(%{"operations" => operations}))

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp lookup(conn, id, status \\ 200),
    do:
      conn
      |> get("/api/v1/operations/#{URI.encode(id, &URI.char_unreserved?/1)}")
      |> json_response(status)

  defp snapshot do
    for schema <- [Group, Room, CreditLot, CreditAllocation, OperationRecord],
        do: Repo.all(schema)
  end

  defp reverse_object_keys(value) when is_map(value) do
    entries =
      value
      |> Enum.sort(:desc)
      |> Enum.map(fn {key, value} ->
        Jason.encode!(key) <> ":" <> reverse_object_keys(value)
      end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp reverse_object_keys(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &reverse_object_keys/1) <> "]"

  defp reverse_object_keys(value), do: Jason.encode!(value)
end
