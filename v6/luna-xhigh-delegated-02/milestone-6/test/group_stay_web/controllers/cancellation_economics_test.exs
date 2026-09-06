defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-18",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp batch(conn, operations) do
    json_post(conn, %{"operations" => operations}) |> json_response(200)
  end

  test "fixes policy at booking and recomputes refundable date after rescheduling", %{conn: conn} do
    assert %{"results" => [opened]} =
             batch(conn, [open_operation(%{"occurred_on" => "2026-12-31"})])

    assert opened["revision"] == 1

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["policy_version"] == "flex-14"
    assert group["refundable_until"] == "2027-03-01"

    assert %{"results" => [moved]} =
             batch(conn, [
               %{
                 "operation_id" => "move-1",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-04-01",
                 "expected_revision" => 1
               }
             ])

    assert moved["policy_version"] == "flex-14"
    assert moved["refundable_until"] == "2027-03-18"
  end

  test "uses the 30-day cutoff and includes advance-purchase policy", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [open_operation()])

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["policy_version"] == "flex-30"
    assert group["refundable_until"] == "2027-02-13"

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               open_operation(%{
                 "group_id" => "advance-1",
                 "operation_id" => "advance-open",
                 "rate_plan" => "advance_purchase"
               })
             ])

    assert %{"data" => advance} =
             get(build_conn(), "/api/v1/groups/advance-1") |> json_response(200)

    assert advance["policy_version"] == "advance-nonrefundable"
    assert advance["refundable_until"] == nil
  end

  test "converts refundable cash to rounded hotel credit and exposes liability", %{conn: conn} do
    assert %{"results" => [_, payment, cancellation]} =
             batch(conn, [
               open_operation(%{
                 "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
               }),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 15
               },
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-02-13",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert payment["revision"] == 2
    assert cancellation["refunded_cents"] == 0
    assert cancellation["retained_cents"] == 0
    assert cancellation["credit_issued_cents"] == 17

    assert %{"data" => credit} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-02-13")
             |> json_response(200)

    assert credit == %{
             "guest_id" => "guest-22",
             "available_cents" => 17,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-1",
                 "remaining_cents" => 17,
                 "expires_on" => "2028-02-14"
               }
             ]
           }

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2027-02-13") |> json_response(200)

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 15,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 17
           }
  end

  test "applies credit by expiry and source id, then restores it without a bonus", %{conn: conn} do
    open =
      open_operation(%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]})

    assert %{"results" => [_, _, first_cancel, second_cancel]} =
             batch(conn, [
               open,
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 2_000
               },
               %{
                 "operation_id" => "cancel-b",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit"
               },
               %{
                 "operation_id" => "open-second",
                 "type" => "open_group",
                 "occurred_on" => "2027-01-04",
                 "group_id" => "group-82",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "arrival_on" => "2027-05-01",
                 "departure_on" => "2027-05-02",
                 "rate_plan" => "flexible",
                 "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 11_000}]
               }
             ])

    assert first_cancel["credit_issued_cents"] == 2_200
    assert second_cancel["status"] == "applied"

    assert %{"results" => [applied]} =
             batch(conn, [
               %{
                 "operation_id" => "apply-1",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-05",
                 "group_id" => "group-82",
                 "amount_cents" => 2_200,
                 "expected_revision" => 1
               }
             ])

    assert applied["revision"] == 2
    assert applied["outstanding_deposit_cents"] == 0

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-82") |> json_response(200)
    assert group["cash_paid_cents"] == 0
    assert group["credit_paid_cents"] == 2_200

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2027-01-05") |> json_response(200)

    assert ledger["credit_liability_cents"] == 2_200
  end

  test "restores applied credit on refundable cancellation and consumes it otherwise", %{
    conn: conn
  } do
    assert %{"results" => [_, _, cancelled]} =
             batch(conn, [
               open_operation(%{
                 "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
               }),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 2_000
               },
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert cancelled["credit_issued_cents"] == 2_200

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               open_operation(%{
                 "operation_id" => "open-2",
                 "group_id" => "group-82",
                 "arrival_on" => "2027-06-01",
                 "departure_on" => "2027-06-02",
                 "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 11_000}]
               })
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "apply-2",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-05",
                 "group_id" => "group-82",
                 "amount_cents" => 2_200
               }
             ])

    assert %{"results" => [cancellation]} =
             batch(conn, [
               %{
                 "operation_id" => "cancel-2",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-02-01",
                 "group_id" => "group-82"
               }
             ])

    assert cancellation["refunded_cents"] == 0
    assert cancellation["retained_cents"] == 0

    assert %{"data" => credit} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-02-01")
             |> json_response(200)

    assert credit["available_cents"] == 2_200
  end

  test "rejects unavailable credit, bad dates, and stale revisions without mutation", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied"}]} = batch(conn, [open_operation()])

    assert %{"results" => [insufficient]} =
             batch(conn, [
               %{
                 "operation_id" => "apply-1",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 1,
                 "expected_revision" => 0
               }
             ])

    assert insufficient["code"] == "stale_revision"
    assert insufficient["actual_revision"] == 1

    assert %{"results" => [insufficient]} =
             batch(conn, [
               %{
                 "operation_id" => "apply-2",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 1
               }
             ])

    assert insufficient["code"] == "insufficient_credit"

    assert get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)

    assert get(build_conn(), "/api/v1/ledger?on=not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=not-a-date")
           |> json_response(422) == %{"error" => %{"code" => "invalid_date"}}
  end

  test "hotel credit is unavailable for non-refundable cancellation", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [open_operation(%{"rate_plan" => "advance_purchase"})])

    assert %{"results" => [rejected]} =
             batch(conn, [
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 1
               }
             ])

    assert rejected["code"] == "refund_method_not_available"

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["status"] == "active"
    assert group["revision"] == 1
  end

  test "non-refundable cancellation consumes applied credit", %{conn: conn} do
    assert %{"results" => [_, _, _]} =
             batch(conn, [
               open_operation(%{
                 "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
               }),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 2_000
               },
               %{
                 "operation_id" => "credit-source",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-02-13",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               open_operation(%{
                 "operation_id" => "advance-open",
                 "group_id" => "group-82",
                 "rate_plan" => "advance_purchase",
                 "arrival_on" => "2027-04-01",
                 "departure_on" => "2027-04-02",
                 "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 2_200}]
               })
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "apply-advance",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-02-14",
                 "group_id" => "group-82",
                 "amount_cents" => 2_200
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "cancel-advance",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-02-15",
                 "group_id" => "group-82"
               }
             ])

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-02-15")
           |> json_response(200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2027-02-15") |> json_response(200)

    assert ledger["credit_liability_cents"] == 0
  end

  test "restored credit that has expired is not available", %{conn: conn} do
    assert %{"results" => [_, _, _]} =
             batch(conn, [
               open_operation(%{
                 "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
               }),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "amount_cents" => 2_000
               },
               %{
                 "operation_id" => "source-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               open_operation(%{
                 "operation_id" => "open-later",
                 "group_id" => "group-82",
                 "arrival_on" => "2028-06-01",
                 "departure_on" => "2028-06-02",
                 "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 11_000}]
               })
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "apply-later",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-05",
                 "group_id" => "group-82",
                 "amount_cents" => 2_200
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "cancel-later",
                 "type" => "cancel_group",
                 "occurred_on" => "2028-01-02",
                 "group_id" => "group-82"
               }
             ])

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2028-01-02")
           |> json_response(200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2028-01-02") |> json_response(200)

    assert ledger["credit_liability_cents"] == 0
  end
end
