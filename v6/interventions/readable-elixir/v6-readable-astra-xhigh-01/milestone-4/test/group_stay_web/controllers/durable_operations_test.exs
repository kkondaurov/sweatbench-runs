defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  import GroupStay.PartnerFixtures

  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Finance.CashEntry
  alias GroupStay.Operations.Record
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  test "retries return original results within and across batches after the group changes", %{
    conn: conn
  } do
    booking = open_group(%{"operation_id" => " Open-É 81 "})
    payment = operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1})
    cancellation = operation("cancel_group", %{"expected_revision" => 2})

    assert [opened, paid, retried_open, retried_payment, cancelled] =
             submit(conn, [booking, payment, booking, payment, cancellation])

    assert retried_open == opened
    assert retried_payment == paid
    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert cancelled["revision"] == 3

    before = snapshot()
    assert submit(conn, [booking, payment, cancellation]) == [opened, paid, cancelled]
    assert snapshot() == before
    assert Repo.aggregate(CashEntry, :count) == 2

    for {operation, result} <-
          Enum.zip([booking, payment, cancellation], [opened, paid, cancelled]) do
      assert read_result(conn, operation["operation_id"]) == %{"data" => result}
    end
  end

  test "a missing-group rejection stays rejected after the group is opened", %{conn: conn} do
    payment = operation("record_cash_payment", %{"amount_cents" => 500})

    [rejected, _, retried, applied] =
      submit(conn, [
        payment,
        open_group(),
        payment,
        Map.put(payment, "operation_id", "new-payment")
      ])

    assert rejected["code"] == "group_not_found"
    assert retried == rejected
    assert applied["revision"] == 2
    assert Repo.get!(Group, "group-81").cash_paid_cents == 500
    assert read_result(conn, payment["operation_id"]) == %{"data" => rejected}
  end

  test "stale results preserve original revision details and cannot be corrected under the same id",
       %{
         conn: conn
       } do
    stale = operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 0})

    [_, rejected, _] =
      submit(conn, [
        open_group(),
        stale,
        operation("record_cash_payment", %{"amount_cents" => 100})
      ])

    assert %{"code" => "stale_revision", "expected_revision" => 0, "actual_revision" => 1} =
             rejected

    before = snapshot()

    assert [^rejected, %{"code" => "operation_id_conflict"}, ^rejected] =
             submit(conn, [stale, Map.put(stale, "expected_revision", 2), stale])

    assert snapshot() == before
    assert read_result(conn, stale["operation_id"]) == %{"data" => rejected}
  end

  test "reschedule retries preserve dates and policy fields after another move", %{conn: conn} do
    move = operation("reschedule_group", %{"new_arrival_on" => "2028-03-01"})

    [_, moved, _] =
      submit(conn, [
        open_group(),
        move,
        operation("reschedule_group", %{"new_arrival_on" => "2029-03-01"})
      ])

    assert %{
             "revision" => 2,
             "new_arrival_on" => "2028-03-01",
             "new_departure_on" => "2028-03-04",
             "policy_version" => "flex-14",
             "refundable_until" => "2028-02-16"
           } = moved

    before = snapshot()
    assert submit(conn, [move]) == [moved]
    assert read_result(conn, move["operation_id"]) == %{"data" => moved}
    assert snapshot() == before
  end

  test "credit issuance, redemption, restoration, and rejected redemption replay without effects",
       %{
         conn: conn
       } do
    operations = [
      open_group(),
      operation("apply_hotel_credit", %{"amount_cents" => 110}),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "next"}),
      operation("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 110}),
      operation("cancel_group", %{"group_id" => "next"})
    ]

    results = submit(conn, operations)

    assert Enum.map(results, & &1["status"]) ==
             ["applied", "rejected", "applied", "applied", "applied", "applied", "applied"]

    assert Enum.at(results, 1)["code"] == "insufficient_credit"
    assert Enum.at(results, 3)["credit_issued_cents"] == 110
    assert List.last(results)["credit_issued_cents"] == 0
    assert [%Lot{remaining_cents: 110}] = Repo.all(Lot)
    assert [%Allocation{status: :restored}] = Repo.all(Allocation)

    before = snapshot()
    assert submit(conn, operations) == results
    assert snapshot() == before
  end

  test "JSON object key order and escape spelling do not affect equivalence", %{conn: conn} do
    # Hand-written JSON exercises ordering at both the operation and nested levels.
    first =
      ~s({"operations":[{"operation_id":"reordered","type":"unknown","details":{"a":1,"b":[{"x":"é","y":null}]}}]})

    retry =
      ~S({"operations":[{"details":{"b":[{"y":null,"x":"\u00e9"}],"a":1},"type":"unknown","operation_id":"reordered"}]})

    [result] = submit_json(conn, first)
    before = snapshot()
    assert submit_json(conn, retry) == [result]
    assert snapshot() == before
  end

  for {label, changes} <- [
        {"type", %{"type" => "cancel_group"}},
        {"group", %{"group_id" => "different"}},
        {"date", %{"occurred_on" => "2026-10-04"}},
        {"extra field", %{"extra" => nil}},
        {"array order", %{"metadata" => %{"values" => [2, 1], "number" => 1}}},
        {"numeric type", %{"metadata" => %{"values" => [1, 2], "number" => 1.0}}},
        {"nested null", %{"metadata" => %{"values" => [1, 2], "number" => nil}}}
      ] do
    test "changing #{label} conflicts without replacing the original submission", %{conn: conn} do
      original = open_group(%{"metadata" => %{"values" => [1, 2], "number" => 1}})
      [result] = submit(conn, [original])
      before = snapshot()
      changed = Map.merge(original, unquote(Macro.escape(changes)))

      assert [%{"code" => "operation_id_conflict", "operation_id" => id}, ^result] =
               submit(conn, [changed, original])

      assert id == original["operation_id"]
      assert snapshot() == before
      assert read_result(conn, id) == %{"data" => result}
    end
  end

  test "room array order and omitted versus explicit defaults remain significant", %{conn: conn} do
    booking = open_group()
    cancellation = operation("cancel_group")
    submit(conn, [booking, cancellation])
    before = snapshot()

    assert [%{"code" => "operation_id_conflict"}, %{"code" => "operation_id_conflict"}] =
             submit(conn, [
               Map.update!(booking, "rooms", &Enum.reverse/1),
               Map.put(cancellation, "refund_method", "cash")
             ])

    assert snapshot() == before
  end

  test "audit retains full applied and malformed submissions in first commit order", %{conn: conn} do
    rejected = %{"operation_id" => "z-first", "type" => ["bad"], "unknown" => [false, nil, %{}]}
    missing_type = %{"operation_id" => "a-second", "extra" => 9_223_372_036_854_775_808}
    booking = open_group(%{"operation_id" => "m-third", "notes" => %{"empty" => "", "n" => 1.5}})

    [first, second, third, retried, conflict] =
      submit(conn, [rejected, missing_type, booking, rejected, Map.put(booking, "notes", nil)])

    assert first["code"] == "invalid_operation"
    assert retried == first
    assert second["code"] == "invalid_operation"
    assert conflict["code"] == "operation_id_conflict"
    records = Repo.all(from record in Record, order_by: record.id)
    assert Enum.map(records, & &1.operation_id) == ["z-first", "a-second", "m-third"]
    assert Enum.map(records, & &1.payload) === [rejected, missing_type, booking]
    assert Enum.map(records, & &1.operation_type) == [nil, nil, "open_group"]
    assert Enum.map(records, & &1.result) == [first, second, third]
    assert read_result(conn, "z-first") == %{"data" => first}
  end

  test "unidentifiable operations reject individually without reserving an identifier", %{
    conn: conn
  } do
    invalid = [nil, [], true, %{}, %{"operation_id" => ""}, %{"operation_id" => 123}]
    results = submit(conn, invalid ++ [open_group()])
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"
    assert Repo.aggregate(Record, :count) == 1
  end

  test "unknown operation identifiers return the usual structured 404", %{conn: conn} do
    assert conn |> get(~p"/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  defp submit(conn, operations), do: submit_json(conn, Jason.encode!(%{operations: operations}))

  defp submit_json(conn, json) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", json)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read_result(conn, id) do
    conn |> recycle() |> get(~p"/api/v1/operations/#{id}") |> json_response(200)
  end

  defp snapshot do
    for schema <- [Group, Room, CashEntry, Lot, Allocation, Record],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
