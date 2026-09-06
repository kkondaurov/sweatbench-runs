defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  test "pins the policy version at booking and recomputes its date on reschedule", %{conn: conn} do
    post_batch(conn, [
      open_operation("old-policy", "2026-12-31", "2027-02-01", "2027-02-03"),
      open_operation("new-policy", "2027-01-01", "2027-02-01", "2027-02-03"),
      open_operation("moved-policy", "2027-01-01", "2027-03-01", "2027-03-03")
    ])

    assert json_response(get(conn, "/api/v1/groups/old-policy"), 200)["data"]
           |> Map.take(["policy_version", "refundable_until"]) ==
             %{"policy_version" => "flex-14", "refundable_until" => "2027-01-18"}

    assert json_response(get(conn, "/api/v1/groups/new-policy"), 200)["data"]
           |> Map.take(["policy_version", "refundable_until"]) ==
             %{"policy_version" => "flex-30", "refundable_until" => "2027-01-02"}

    assert %{"results" => [moved]} =
             post_batch(conn, [
               %{
                 "operation_id" => "move-policy",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "moved-policy",
                 "new_arrival_on" => "2027-04-01",
                 "expected_revision" => 1
               }
             ])

    assert moved == %{
             "operation_id" => "move-policy",
             "status" => "applied",
             "group_id" => "moved-policy",
             "new_arrival_on" => "2027-04-01",
             "new_departure_on" => "2027-04-03",
             "policy_version" => "flex-30",
             "refundable_until" => "2027-03-02",
             "revision" => 2
           }
  end

  test "issues, redeems, restores, and accounts for hotel credit", %{conn: conn} do
    post_batch(conn, [open_operation("credit-source", "2026-12-01", "2027-02-01", "2027-02-02")])

    assert %{"results" => [_payment, cancelled]} =
             post_batch(conn, [
               cash_payment("source-pay", "credit-source", 100, "2026-12-01"),
               cancellation("source-cancel", "credit-source", "2026-12-02", "hotel_credit")
             ])

    assert cancelled == %{
             "operation_id" => "source-cancel",
             "status" => "applied",
             "group_id" => "credit-source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 110,
             "revision" => 3
           }

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2026-12-02"), 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-12-03"
                 }
               ]
             }
           }

    assert json_response(get(conn, "/api/v1/ledger?on=2026-12-02"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 100,
               "credit_liability_cents" => 110
             }
           }

    post_batch(conn, [open_operation("credit-user", "2027-01-01", "2027-03-01", "2027-03-02")])

    assert %{"results" => [applied]} =
             post_batch(conn, [
               %{
                 "operation_id" => "credit-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit-user",
                 "amount_cents" => 100,
                 "expected_revision" => 1
               }
             ])

    assert applied == %{
             "operation_id" => "credit-apply",
             "status" => "applied",
             "group_id" => "credit-user",
             "amount_cents" => 100,
             "outstanding_deposit_cents" => 0,
             "revision" => 2
           }

    assert json_response(get(conn, "/api/v1/groups/credit-user"), 200)["data"]
           |> Map.take(["deposit_paid_cents", "cash_paid_cents", "credit_paid_cents"]) ==
             %{
               "deposit_paid_cents" => 100,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 100
             }

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-01"), 200)["data"]
           |> Map.take(["available_cents", "lots"]) ==
             %{
               "available_cents" => 10,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel",
                   "remaining_cents" => 10,
                   "expires_on" => "2027-12-03"
                 }
               ]
             }

    assert %{"results" => [restored]} =
             post_batch(conn, [cancellation("credit-cancel", "credit-user", "2027-01-02")])

    assert restored["refunded_cents"] == 0
    assert restored["retained_cents"] == 0
    assert restored["credit_issued_cents"] == 0

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-02"), 200)["data"]
           |> Map.take(["available_cents", "lots"]) ==
             %{
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-12-03"
                 }
               ]
             }
  end

  test "does not offer credit on non-refundable cancellation and consumes it otherwise", %{
    conn: conn
  } do
    post_batch(conn, [open_operation("credit-source-2", "2026-12-01", "2027-02-01", "2027-02-02")])

    post_batch(conn, [
      cash_payment("source-pay-2", "credit-source-2", 100, "2026-12-01"),
      cancellation("source-cancel-2", "credit-source-2", "2026-12-02", "hotel_credit"),
      open_operation(
        "advance-credit-user",
        "2026-12-01",
        "2027-03-01",
        "2027-03-02",
        "advance_purchase"
      )
    ])

    assert %{"results" => [applied]} =
             post_batch(conn, [
               %{
                 "operation_id" => "advance-credit-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-12-03",
                 "group_id" => "advance-credit-user",
                 "amount_cents" => 100
               }
             ])

    assert applied["revision"] == 2

    assert %{"results" => [unavailable]} =
             post_batch(conn, [
               cancellation(
                 "advance-credit-cancel-credit",
                 "advance-credit-user",
                 "2026-12-04",
                 "hotel_credit"
               )
             ])

    assert unavailable["code"] == "refund_method_not_available"

    assert %{"results" => [cancelled]} =
             post_batch(conn, [
               cancellation("advance-credit-cancel", "advance-credit-user", "2026-12-04")
             ])

    assert cancelled["retained_cents"] == 0

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2026-12-04"), 200)["data"]
           |> Map.take(["available_cents", "lots"]) ==
             %{
               "available_cents" => 10,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel-2",
                   "remaining_cents" => 10,
                   "expires_on" => "2027-12-03"
                 }
               ]
             }

    assert %{"results" => [_opened, insufficient]} =
             post_batch(conn, [
               open_operation("credit-insufficient", "2026-12-01", "2027-03-01", "2027-03-02"),
               %{
                 "operation_id" => "credit-too-much",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-12-05",
                 "group_id" => "credit-insufficient",
                 "amount_cents" => 11
               }
             ])

    assert insufficient["code"] == "insufficient_credit"
    assert insufficient["group_id"] == "credit-insufficient"

    assert json_response(get(conn, "/api/v1/groups/credit-insufficient"), 200)["data"]
           |> Map.take(["revision", "deposit_paid_cents"]) ==
             %{"revision" => 1, "deposit_paid_cents" => 0}
  end

  test "treats a lot as available through its expiry date", %{conn: conn} do
    post_batch(conn, [open_operation("expiring-source", "2026-12-01", "2027-02-01", "2027-02-02")])

    post_batch(conn, [
      cash_payment("expiring-pay", "expiring-source", 5, "2026-12-01"),
      cancellation("expiring-cancel", "expiring-source", "2026-12-02", "hotel_credit")
    ])

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-12-02"), 200)["data"]
           |> Map.take(["available_cents", "lots"]) ==
             %{
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "expiring-cancel",
                   "remaining_cents" => 6,
                   "expires_on" => "2027-12-03"
                 }
               ]
             }

    assert json_response(get(conn, "/api/v1/ledger?on=2027-12-03"), 200)["data"]
           |> Map.take(["credit_liability_cents"]) == %{"credit_liability_cents" => 0}
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(group_id, booked_on, arrival_on, departure_on, rate_plan \\ "flexible") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => departure_on,
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancellation(operation_id, group_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end
end
