defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp issue_credit(conn, group_id, guest_id, operation_id, occurred_on, amount_cents) do
    post_batch(conn, [
      operation(%{
        "operation_id" => "open-#{group_id}",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16"
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-#{group_id}",
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount_cents,
        "occurred_on" => "2027-01-02"
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  test "fixes policy at booking and recomputes the refundable date on reschedule", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [operation()])

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-02-13"
             }
           } = get(conn, "/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "results" => [
               %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-03-02",
                 "revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-move",
                 "type" => "reschedule_group",
                 "group_id" => "group-81",
                 "occurred_on" => "2027-01-02",
                 "new_arrival_on" => "2027-04-01",
                 "expected_revision" => 1
               })
             ])
  end

  test "converts refundable cash to credit and exposes the separate ledger totals", %{conn: conn} do
    post_batch(conn, [operation()])

    post_batch(conn, [
      operation(%{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "amount_cents" => 2_000
      })
    ])

    assert %{
             "results" => [
               %{
                 "credit_issued_cents" => 2_200,
                 "refunded_cents" => 0,
                 "retained_cents" => 0
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "cancel-17",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-10",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert %{
             "data" => %{
               "available_cents" => 2_200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 2_200,
                   "expires_on" => "2028-01-10"
                 }
               ]
             }
           } = get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-10") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 2_000,
               "credit_liability_cents" => 2_200
             }
           } = get(conn, "/api/v1/ledger?on=2027-01-10") |> json_response(200)
  end

  test "consumes credit in expiry/source order and restores the original lots on refundable cancellation",
       %{conn: conn} do
    issue_credit(conn, "source-a", "guest-22", "cancel-a", "2027-01-01", 1_000)
    issue_credit(conn, "source-b", "guest-22", "cancel-b", "2027-01-02", 2_000)

    post_batch(conn, [
      operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "guest_id" => "guest-22",
        "arrival_on" => "2028-03-01",
        "departure_on" => "2028-03-02",
        "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 15_000}]
      })
    ])

    assert %{"results" => [%{"amount_cents" => 2_000, "revision" => 2}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "group_id" => "target",
                 "amount_cents" => 2_000,
                 "occurred_on" => "2027-02-01"
               })
             ])

    assert %{
             "data" => %{
               "deposit_paid_cents" => 2_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 2_000,
               "outstanding_deposit_cents" => 1_000
             }
           } = get(conn, "/api/v1/groups/target") |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 1_300,
               "lots" => [
                 %{"source_operation_id" => "cancel-b", "remaining_cents" => 1_300}
               ]
             }
           } = get(conn, "/api/v1/guests/guest-22/credit?on=2027-02-01") |> json_response(200)

    post_batch(conn, [
      operation(%{
        "operation_id" => "cancel-target",
        "type" => "cancel_group",
        "group_id" => "target",
        "occurred_on" => "2027-02-02"
      })
    ])

    assert %{
             "data" => %{
               "available_cents" => 3_300,
               "lots" => [
                 %{"source_operation_id" => "cancel-a", "remaining_cents" => 1_100},
                 %{"source_operation_id" => "cancel-b", "remaining_cents" => 2_200}
               ]
             }
           } = get(conn, "/api/v1/guests/guest-22/credit?on=2027-02-02") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 3_300}} =
             get(conn, "/api/v1/ledger?on=2027-02-02") |> json_response(200)
  end

  test "rejects hotel credit for a non-refundable cancellation without changing the group", %{
    conn: conn
  } do
    post_batch(conn, [
      operation(%{
        "group_id" => "advance-group",
        "rate_plan" => "advance_purchase"
      })
    ])

    assert %{
             "results" => [%{"code" => "refund_method_not_available", "status" => "rejected"}]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "cancel-advance",
                 "type" => "cancel_group",
                 "group_id" => "advance-group",
                 "occurred_on" => "2027-01-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert %{"data" => %{"revision" => 1, "status" => "active"}} =
             get(conn, "/api/v1/groups/advance-group") |> json_response(200)
  end

  test "expired credit is omitted and does not return when restored after expiry", %{conn: conn} do
    issue_credit(conn, "source", "guest-22", "cancel-source", "2027-01-01", 1_000)

    post_batch(conn, [
      operation(%{
        "operation_id" => "open-target",
        "group_id" => "late-target",
        "guest_id" => "guest-22",
        "arrival_on" => "2028-03-01",
        "departure_on" => "2028-03-02",
        "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 10_000}]
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "apply-late-credit",
        "type" => "apply_hotel_credit",
        "group_id" => "late-target",
        "amount_cents" => 1_000,
        "occurred_on" => "2027-12-01"
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "cancel-late-target",
        "type" => "cancel_group",
        "group_id" => "late-target",
        "occurred_on" => "2028-01-02"
      })
    ])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(conn, "/api/v1/guests/guest-22/credit?on=2028-01-02") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2028-01-02") |> json_response(200)
  end

  test "stale and insufficient credit attempts leave revision and credit unchanged", %{conn: conn} do
    issue_credit(conn, "source", "guest-22", "cancel-source", "2027-01-01", 1_000)

    post_batch(conn, [
      operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "guest_id" => "guest-22",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 10_000}]
      })
    ])

    assert %{"results" => [%{"code" => "stale_revision"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "stale-credit",
                 "type" => "apply_hotel_credit",
                 "group_id" => "target",
                 "amount_cents" => 1_200,
                 "occurred_on" => "2027-02-01",
                 "expected_revision" => 2
               })
             ])

    assert %{"results" => [%{"code" => "insufficient_credit"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "insufficient-credit",
                 "type" => "apply_hotel_credit",
                 "group_id" => "target",
                 "amount_cents" => 1_200,
                 "occurred_on" => "2027-02-01"
               })
             ])

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get(conn, "/api/v1/groups/target") |> json_response(200)

    assert %{"data" => %{"available_cents" => 1_100}} =
             get(conn, "/api/v1/guests/guest-22/credit?on=2027-02-01") |> json_response(200)
  end
end
