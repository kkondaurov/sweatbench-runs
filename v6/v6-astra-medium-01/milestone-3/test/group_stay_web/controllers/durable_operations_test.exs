defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixture
  import Ecto.Query
  alias GroupStay.{Operation, Repo, Reservations}

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(id) do
    build_conn()
    |> get("/api/v1/operations/#{id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "whole batch replay preserves all results, revisions, cash, credit and audit order" do
    ops = [
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100}),
      operation("move", "reschedule_group", %{"new_arrival_on" => "2027-07-01"}),
      operation("cancel", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target-open", "target"),
      operation("credit", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      operation("restore", "cancel_group", %{"group_id" => "target"})
    ]

    results = batch(ops)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    before =
      {Reservations.ledger(~D[2027-05-02]), Reservations.guest_credit("guest", ~D[2027-05-02])}

    assert batch(ops) == results
    assert batch(Enum.reverse(ops)) == Enum.reverse(results)

    assert {Reservations.ledger(~D[2027-05-02]),
            Reservations.guest_credit("guest", ~D[2027-05-02])} == before

    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.submission) == ops
    assert Enum.map(records, & &1.type) == Enum.map(ops, & &1["type"])
    assert Enum.map(records, & &1.result) == results
    for result <- results, do: assert(read(result["operation_id"]) == result)
  end

  test "duplicates within one batch replay and later retries do not depend on group existence" do
    open = opening()
    pay = operation("pay", "record_cash_payment", %{"amount_cents" => 10})
    [opened, opened_again, paid, paid_again] = batch([open, open, pay, pay])
    assert opened_again == opened
    assert paid_again == paid
    assert Reservations.get_group("group").revision == 2
    assert Reservations.ledger().cash_held_cents == 10

    Repo.delete_all(GroupStay.Group)
    assert batch([open, pay]) == [opened, paid]
    assert Reservations.get_group("group") == nil
    assert Repo.aggregate(Operation, :count) == 2
  end

  test "rejections survive later state changes and corrected revisions conflict" do
    missing = operation("missing", "record_cash_payment", %{"amount_cents" => 10})

    stale =
      operation("stale", "cancel_group", %{"expected_revision" => 0, "refund_method" => "bad"})

    [rejected, _, original_stale, _] =
      batch([
        missing,
        opening(),
        stale,
        operation("pay", "record_cash_payment", %{"amount_cents" => 10})
      ])

    assert rejected["code"] == "group_not_found"
    assert original_stale["actual_revision"] == 1
    assert batch([missing, stale]) == [rejected, original_stale]

    assert [%{"code" => "operation_id_conflict"}, %{"revision" => 3}] =
             batch([
               Map.put(stale, "expected_revision", 2),
               operation("pay2", "record_cash_payment", %{"amount_cents" => 1})
             ])

    assert read("stale") == original_stale
    assert read("missing") == rejected
  end

  test "complete JSON is retained; nested key order is irrelevant but arrays and values matter" do
    op =
      Map.put(opening(), "extra", %{"z" => [1, true, nil, %{"b" => 2, "a" => 1}], "a" => "text"})

    [original] = batch([op])
    # Send literal JSON with object keys reversed at every level.
    reordered = fn encode, value ->
      cond do
        is_map(value) ->
          "{" <>
            (value
             |> Enum.sort(:desc)
             |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> encode.(encode, v) end)) <>
            "}"

        is_list(value) ->
          "[" <> Enum.map_join(value, ",", &encode.(encode, &1)) <> "]"

        true ->
          Jason.encode!(value)
      end
    end

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(
             "/api/v1/partner-batches",
             "{\"operations\":[" <> reordered.(reordered, op) <> "]}"
           )
           |> json_response(200) == %{"results" => [original]}

    for changed <- [
          Map.put(op, "rooms", Enum.reverse(op["rooms"])),
          Map.delete(op, "extra"),
          put_in(op, ["extra", "z"], [1.0, true, nil, %{"a" => 1, "b" => 2}]),
          Map.put(op, "expected_revision", nil)
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert Repo.get_by!(Operation, operation_id: "open").submission == op
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "identifiable invalid operations are remembered, missing identifiers remain invalid" do
    for op <- [
          %{"operation_id" => "unknown", "type" => "unknown", "extra" => [1, 2]},
          %{"operation_id" => "incomplete", "type" => "open_group"},
          %{"operation_id" => "bad-type", "type" => ["invalid"]}
        ] do
      [result] = batch([op])
      assert result["code"] == "invalid_operation"
      assert batch([op]) == [result]
      assert read(op["operation_id"]) == result
      assert Repo.get_by!(Operation, operation_id: op["operation_id"]).submission == op
    end

    for op <- [nil, [], %{}, %{"operation_id" => ""}, %{"operation_id" => 42}] do
      assert [%{"code" => "invalid_operation"}] = batch([op])
    end

    assert Repo.aggregate(Operation, :count) == 3

    assert build_conn() |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end
end
