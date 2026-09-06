defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  defp opening(id \\ "group", fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "b", "nightly_rate_cents" => 500},
          %{"room_id" => "a", "nightly_rate_cents" => 500}
        ]
      },
      fields
    )
  end

  defp operation(id, type, fields) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-01-02"
      },
      fields
    )
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(conn, id) do
    conn |> get(~p"/api/v1/operations/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp records, do: Repo.all(from o in Operation, order_by: o.id)
  defp domain, do: for(schema <- [Group, CreditLot, CreditAllocation], do: Repo.all(schema))

  test "whole batches replay every operation type and retain complete ordered audit records", %{
    conn: conn
  } do
    operations = [
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
      operation("move", "reschedule_group", %{"new_arrival_on" => "2027-04-01"}),
      operation("source", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target"),
      operation("credit", "apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 100,
        "expected_revision" => 1
      }),
      operation("restore", "cancel_group", %{"group_id" => "target"}),
      operation("rejected", "record_cash_payment", %{"amount_cents" => 1})
    ]

    results = submit(conn, operations)

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied applied applied applied applied applied rejected)

    before = domain()
    audit = records()
    assert submit(conn, operations) == results
    assert submit(conn, operations ++ operations) == results ++ results
    assert domain() == before
    assert records() == audit
    assert Enum.map(audit, & &1.submission) == operations
    assert Enum.map(audit, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(audit, & &1.result) == results

    for result <- results, do: assert(read(conn, result["operation_id"]) == result)
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4, 1, 2, 3, nil]
  end

  test "object key order is irrelevant at every depth, while arrays and values are significant",
       %{
         conn: conn
       } do
    submission = opening("group", %{"extra" => %{"a" => [1, true, nil], "b" => "Ω"}})
    [original] = submit(conn, [submission])

    # Send literal JSON with reversed object keys, including nested room objects.
    reordered =
      ~s({"operations":[{"extra":{"b":"Ω","a":[1,true,null]},"rooms":[{"nightly_rate_cents":500,"room_id":"b"},{"nightly_rate_cents":500,"room_id":"a"}],"rate_plan":"flexible","departure_on":"2027-03-02","arrival_on":"2027-03-01","occurred_on":"2027-01-01","property_id":"hotel","guest_id":"guest","group_id":"group","type":"open_group","operation_id":"open-group"}]})

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(~p"/api/v1/partner-batches", reordered)
           |> json_response(200) == %{"results" => [original]}

    changed = [
      Map.put(submission, "rooms", Enum.reverse(submission["rooms"])),
      put_in(submission, ["extra", "a"], [true, 1, nil]),
      put_in(submission, ["extra", "a"], [1.0, true, nil]),
      Map.delete(submission, "extra"),
      Map.put(submission, "unused", nil),
      Map.put(submission, "guest_id", "someone-else"),
      Map.put(submission, "type", "cancel_group")
    ]

    before = domain()

    for payload <- changed do
      assert submit(conn, [payload]) == [
               %{
                 "operation_id" => "open-group",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
    end

    assert domain() == before
    assert [record] = records()
    assert record.submission === submission
    assert read(conn, "open-group") == original
    assert submit(conn, [submission]) == [original]
  end

  test "missing-group and stale rejections replay their original details after state changes", %{
    conn: conn
  } do
    payment = operation("pay", "record_cash_payment", %{"amount_cents" => 1})
    [missing] = submit(conn, [payment])
    assert missing["code"] == "group_not_found"
    submit(conn, [opening()])
    assert submit(conn, [payment]) == [missing]

    stale = Map.merge(payment, %{"operation_id" => "stale", "expected_revision" => 0})
    [rejected] = submit(conn, [stale])
    assert rejected["actual_revision"] == 1
    assert rejected["expected_revision"] == 0

    [applied] = submit(conn, [Map.put(payment, "operation_id", "new-pay")])
    assert applied["revision"] == 2
    assert submit(conn, [stale]) == [rejected]
    assert read(conn, "stale") == rejected

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(stale, "expected_revision", 2)])

    assert Repo.get!(Group, "group").revision == 2
    assert length(records()) == 4
  end

  test "invalid submissions with usable identifiers are audited and remembered", %{conn: conn} do
    invalid = [
      %{"operation_id" => "unknown", "type" => "unknown", "arbitrary" => [nil, %{"x" => 1}]},
      %{"operation_id" => "missing-type", "extra" => false},
      %{"operation_id" => "bad-type", "type" => %{"nested" => [1, 2]}},
      opening("invalid", %{"rooms" => []})
    ]

    results = submit(conn, invalid)

    assert Enum.map(results, & &1["code"]) ==
             ~w(invalid_operation invalid_operation invalid_operation invalid_rooms)

    assert submit(conn, invalid) == results
    assert Enum.map(records(), & &1.submission) == invalid
    for result <- results, do: assert(read(conn, result["operation_id"]) == result)

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [opening("invalid")])

    assert Repo.all(Group) == []
  end

  test "handled rejections and conflicts allow later operations to proceed in order", %{
    conn: conn
  } do
    payment = operation("pay", "record_cash_payment", %{"amount_cents" => 1})

    results =
      submit(conn, [
        opening(),
        payment,
        payment,
        Map.put(payment, "amount_cents", 2),
        operation("bad", "record_cash_payment", %{"amount_cents" => -1}),
        operation("next", "record_cash_payment", %{"amount_cents" => 2, "expected_revision" => 2})
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied applied rejected rejected applied)

    assert Enum.at(results, 1) == Enum.at(results, 2)
    assert List.last(results)["revision"] == 3
    assert Repo.get!(Group, "group").cash_paid_cents == 3
    assert Enum.map(records(), & &1.operation_id) == ~w(open-group pay bad next)
  end

  test "read returns only the stored result and preserves partner identifiers", %{conn: conn} do
    id = " Op Ω "

    [result] =
      submit(conn, [opening("group", %{"operation_id" => id, "private" => "audit only"})])

    assert read(conn, id) == result

    assert conn |> get(~p"/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end
end
