defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
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

  test "opens, funds, reschedules, cancels, and reads a group", %{conn: conn} do
    assert %{
             "results" => [
               %{
                 "deposit_due_cents" => 19_500,
                 "group_id" => "group-81",
                 "revision" => 1,
                 "status" => "applied"
               }
             ]
           } = post_batch(conn, [operation()])

    assert %{"results" => [%{"outstanding_deposit_cents" => 9_500, "revision" => 2}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-payment",
                 "type" => "record_cash_payment",
                 "amount_cents" => 10_000,
                 "expected_revision" => 1
               })
             ])

    assert %{"results" => [%{"revision" => 3, "status" => "applied"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-move",
                 "type" => "reschedule_group",
                 "new_arrival_on" => "2026-12-12",
                 "expected_revision" => 2
               })
             ])

    assert %{"data" => group} = get(conn, "/api/v1/groups/group-81") |> json_response(200)
    assert group["arrival_on"] == "2026-12-12"
    assert group["departure_on"] == "2026-12-15"
    assert group["deposit_paid_cents"] == 10_000
    assert group["outstanding_deposit_cents"] == 9_500

    assert %{"results" => [%{"refunded_cents" => 10_000, "revision" => 4}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-20",
                 "expected_revision" => 3
               })
             ])

    assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
             get(conn, "/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "processes a batch in order and keeps later operations after a rejection", %{conn: conn} do
    assert %{"results" => [open_result, rejected, payment_result]} =
             post_batch(conn, [
               operation(),
               operation(%{"operation_id" => "op-duplicate"}),
               operation(%{
                 "operation_id" => "op-payment",
                 "type" => "record_cash_payment",
                 "amount_cents" => 19_500
               })
             ])

    assert open_result["revision"] == 1
    assert rejected["code"] == "group_already_exists"
    assert payment_result["revision"] == 2
    assert payment_result["outstanding_deposit_cents"] == 0
  end

  test "rejects stale revisions before other validation", %{conn: conn} do
    post_batch(conn, [operation()])

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-payment",
                 "type" => "record_cash_payment",
                 "amount_cents" => 1_000
               })
             ])

    assert %{
             "results" => [
               %{
                 "actual_revision" => 2,
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "group_id" => "group-81"
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-stale",
                 "type" => "record_cash_payment",
                 "amount_cents" => -1,
                 "expected_revision" => 1
               })
             ])
  end

  test "reports invalid batches and missing groups with the documented status", %{conn: conn} do
    conn = put_req_header(conn, "content-type", "application/json")

    assert %{"error" => %{"code" => "invalid_batch"}} =
             post(conn, "/api/v1/partner-batches", Jason.encode!(%{})) |> json_response(422)

    assert %{"results" => [%{"code" => "group_not_found", "status" => "rejected"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "op-missing",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "missing"
               }
             ])
  end

  test "calculates flexible deposits per room and charges advance purchase in full", %{conn: conn} do
    assert %{"results" => [%{"deposit_due_cents" => 2, "revision" => 1}]} =
             post_batch(conn, [
               operation(%{
                 "group_id" => "group-rounded",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 3},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 3}
                 ],
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-11"
               })
             ])

    assert %{"results" => [%{"deposit_due_cents" => 20_000}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-advance",
                 "group_id" => "group-advance",
                 "rate_plan" => "advance_purchase",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-12",
                 "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
               })
             ])

    assert %{
             "data" => %{
               "lodging_total_cents" => 20_000,
               "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
             }
           } = get(conn, "/api/v1/groups/group-advance") |> json_response(200)
  end

  test "returns stable domain rejection codes without changing the group", %{conn: conn} do
    post_batch(conn, [operation()])

    invalid_operations = [
      operation(%{
        "operation_id" => "op-bad-amount",
        "type" => "record_cash_payment",
        "amount_cents" => 0
      }),
      operation(%{
        "operation_id" => "op-too-much",
        "type" => "record_cash_payment",
        "amount_cents" => 19_501
      }),
      operation(%{
        "operation_id" => "op-bad-move",
        "type" => "reschedule_group",
        "new_arrival_on" => "2026-10-03"
      })
    ]

    assert %{"results" => [bad_amount, too_much, bad_move]} =
             post_batch(conn, invalid_operations)

    assert bad_amount["code"] == "invalid_amount"
    assert too_much["code"] == "payment_exceeds_outstanding"
    assert bad_move["code"] == "invalid_stay"

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get(conn, "/api/v1/groups/group-81") |> json_response(200)
  end

  test "retains non-refundable cash and rejects operations after cancellation", %{conn: conn} do
    post_batch(conn, [
      operation(%{
        "group_id" => "group-retained",
        "rate_plan" => "advance_purchase"
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "group_id" => "group-retained",
        "amount_cents" => 97_500
      })
    ])

    assert %{"results" => [%{"refunded_cents" => 0, "retained_cents" => 97_500}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-cancel",
                 "type" => "cancel_group",
                 "group_id" => "group-retained",
                 "occurred_on" => "2026-11-20"
               })
             ])

    assert %{"results" => [%{"code" => "group_not_active"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "op-late-payment",
                 "type" => "record_cash_payment",
                 "group_id" => "group-retained",
                 "amount_cents" => 1
               })
             ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 97_500
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end
end
