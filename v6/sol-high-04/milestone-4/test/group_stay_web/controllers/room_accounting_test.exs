defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  test "allocates by room, reduces in reverse fill order, settles selected rooms, and reconciles payments",
       %{conn: conn} do
    submit(conn, [
      open("group", [room("a", 500), room("b", 500)]),
      cash("pay-1", "group", 150),
      cash("pay-2", "group", 50)
    ])

    assert Enum.map(
             group(conn, "group")["rooms"],
             &Map.take(&1, ["room_id", "deposit_due_cents", "cash_paid_cents", "status"])
           ) == [
             %{
               "room_id" => "a",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 100,
               "status" => "active"
             },
             %{
               "room_id" => "b",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 100,
               "status" => "active"
             }
           ]

    reduced = submit(conn, [reduce("reduce-1", "pay-1", 60, 3)]) |> only_result()

    assert Map.take(reduced, ["amount_cents", "outstanding_deposit_cents", "revision"]) == %{
             "amount_cents" => 60,
             "outstanding_deposit_cents" => 60,
             "revision" => 4
           }

    assert Enum.map(group(conn, "group")["rooms"], & &1["cash_paid_cents"]) == [90, 50]

    cancelled =
      submit(conn, [cancel_rooms("cancel-b", "group", ["b"], "2026-10-05", 4)]) |> only_result()

    assert Map.take(cancelled, ["cancelled_room_ids", "refunded_cents", "revision"]) == %{
             "cancelled_room_ids" => ["b"],
             "refunded_cents" => 50,
             "revision" => 5
           }

    view = group(conn, "group")
    assert view["status"] == "active"
    assert view["deposit_due_cents"] == 100
    assert view["cash_paid_cents"] == 90
    assert Enum.at(view["rooms"], 1)["status"] == "cancelled"

    assert payment(conn, "pay-1") |> Map.take(["recorded_cents", "held_cents", "reduced_cents"]) ==
             %{"recorded_cents" => 150, "held_cents" => 90, "reduced_cents" => 60}

    assert payment(conn, "pay-2") |> Map.take(["recorded_cents", "refunded_cents"]) ==
             %{"recorded_cents" => 50, "refunded_cents" => 50}

    submit(conn, [chargeback("cb-2", "pay-2", 5), chargeback("cb-1", "pay-1", 6)])
    view = group(conn, "group")
    assert view["outstanding_deposit_cents"] == 100
    ledger = ledger(conn, "2026-10-06")

    assert Map.take(ledger, [
             "cash_refunded_cents",
             "cash_reduced_cents",
             "cash_charged_back_cents"
           ]) ==
             %{
               "cash_refunded_cents" => 0,
               "cash_reduced_cents" => 60,
               "cash_charged_back_cents" => 140
             }
  end

  test "chargeback revokes telescoped credit entitlement and restored credit absorbs shortfall",
       %{conn: conn} do
    submit(conn, [
      open("source", [room("room", 100)]),
      cash("pay-a", "source", 5),
      cash("pay-b", "source", 5)
    ])

    submit(conn, [cancel("convert", "source", "2026-10-05", "hotel_credit")])
    assert credit(conn, "guest", "2026-10-05")["available_cents"] == 11

    submit(conn, [open("target", [room("room", 100)]), apply_credit("use", "target", 11)])
    assert group(conn, "target")["credit_paid_cents"] == 11

    result = submit(conn, [chargeback("cb-a", "pay-a", 4)]) |> only_result()
    assert result["charged_back_cents"] == 5
    assert group(conn, "target")["revision"] == 2
    assert ledger(conn, "2026-10-07")["credit_shortfall_cents"] == 6
    assert ledger(conn, "2026-10-07")["credit_liability_cents"] == 11

    submit(conn, [cancel("cancel-target", "target", "2026-10-08")])
    assert credit(conn, "guest", "2026-10-08")["available_cents"] == 5
    assert ledger(conn, "2026-10-08")["credit_shortfall_cents"] == 0
    assert ledger(conn, "2026-10-08")["credit_liability_cents"] == 5
  end

  test "validates selected rooms and payment targets without changing revisions", %{conn: conn} do
    submit(conn, [open("group", [room("a", 500), room("b", 500)]), cash("pay", "group", 10)])

    bad =
      submit(conn, [cancel_rooms("bad", "group", ["a", "a"], "2026-10-05", 2)]) |> only_result()

    assert bad["code"] == "invalid_rooms"
    assert group(conn, "group")["revision"] == 2

    assert submit(conn, [reduce("too-much", "pay", 11, 2)]) |> only_result() |> Map.fetch!("code") ==
             "reduction_exceeds_held_cash"

    assert submit(conn, [reduce("stale", "pay", 0, 1)]) |> only_result() |> Map.fetch!("code") ==
             "stale_revision"

    conn = get(conn, "/api/v1/payments/open-group")
    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    conn = get(conn, "/api/v1/payments/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  defp submit(conn, operations),
    do:
      conn |> post("/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)

  defp only_result(%{"results" => [result]}), do: result

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp payment(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn, on),
    do: conn |> get("/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")

  defp credit(conn, guest, on),
    do:
      conn
      |> get("/api/v1/guests/#{guest}/credit?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp room(id, rate), do: %{"room_id" => id, "nightly_rate_cents" => rate}

  defp open(id, rooms),
    do: %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => rooms
    }

  defp cash(id, group, amount),
    do: %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group,
      "amount_cents" => amount
    }

  defp reduce(id, payment, amount, revision),
    do: %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-04",
      "payment_operation_id" => payment,
      "amount_cents" => amount,
      "expected_revision" => revision
    }

  defp chargeback(id, payment, revision),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => payment,
      "expected_revision" => revision
    }

  defp cancel_rooms(id, group, ids, date, revision),
    do: %{
      "operation_id" => id,
      "type" => "cancel_rooms",
      "occurred_on" => date,
      "group_id" => group,
      "room_ids" => ids,
      "expected_revision" => revision
    }

  defp cancel(id, group, date, method \\ nil) do
    operation = %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => date,
      "group_id" => group
    }

    if method, do: Map.put(operation, "refund_method", method), else: operation
  end

  defp apply_credit(id, group, amount),
    do: %{
      "operation_id" => id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => group,
      "amount_cents" => amount
    }
end
