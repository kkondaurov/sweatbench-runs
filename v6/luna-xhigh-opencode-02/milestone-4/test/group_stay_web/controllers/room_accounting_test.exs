defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "property-1",
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
    )
  end

  test "allocates funding by room and settles only selected rooms", %{conn: conn} do
    operations = [
      open("room-group"),
      %{
        "operation_id" => "room-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "room-group",
        "amount_cents" => 2_500
      },
      %{
        "operation_id" => "cancel-room",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-01-03",
        "group_id" => "room-group",
        "room_ids" => ["room-a"]
      }
    ]

    assert %{"results" => [_, payment, cancellation]} =
             json_response(submit(conn, operations), 200)

    assert payment["revision"] == 2
    assert cancellation["cancelled_room_ids"] == ["room-a"]
    assert cancellation["refunded_cents"] == 2_000

    assert %{
             "data" => %{
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2_000,
               "deposit_paid_cents" => 500,
               "outstanding_deposit_cents" => 1_500,
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 500}
               ]
             }
           } = json_response(get(conn, "/api/v1/groups/room-group"), 200)

    assert %{"data" => payment_data} =
             json_response(get(conn, "/api/v1/payments/room-payment"), 200)

    assert payment_data == %{
             "payment_operation_id" => "room-payment",
             "original_group_id" => "room-group",
             "recorded_cents" => 2_500,
             "held_cents" => 500,
             "refunded_cents" => 2_000,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }
  end

  test "reduces held cash in reverse fill order and charges it back", %{conn: conn} do
    operations = [
      open("reduction-group"),
      %{
        "operation_id" => "reduction-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "reduction-group",
        "amount_cents" => 2_500
      },
      %{
        "operation_id" => "reduce-payment",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "reduction-payment",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "chargeback-payment",
        "type" => "charge_back_payment",
        "payment_operation_id" => "reduction-payment"
      }
    ]

    assert %{"results" => [_, _, reduction, chargeback]} =
             json_response(submit(conn, operations), 200)

    assert reduction["outstanding_deposit_cents"] == 2_500
    assert chargeback["charged_back_cents"] == 1_500

    assert %{"data" => payment} =
             json_response(get(conn, "/api/v1/payments/reduction-payment"), 200)

    assert payment["held_cents"] == 0
    assert payment["reduced_cents"] == 1_000
    assert payment["charged_back_cents"] == 1_500

    assert %{"data" => ledger} = json_response(get(conn, "/api/v1/ledger"), 200)
    assert ledger["cash_reduced_cents"] == 1_000
    assert ledger["cash_charged_back_cents"] == 1_500
  end

  test "chargebacks revoke credit entitlement and track a shortfall", %{conn: conn} do
    operations = [
      open("credit-source", %{
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }),
      %{
        "operation_id" => "credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target"),
      %{
        "operation_id" => "credit-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "credit-target",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "credit-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "credit-payment"
      }
    ]

    assert %{"results" => [_, _, _, _, _, chargeback]} =
             json_response(submit(conn, operations), 200)

    assert chargeback["charged_back_cents"] == 1_000

    assert %{"data" => ledger} = json_response(get(conn, "/api/v1/ledger"), 200)
    assert ledger["credit_liability_cents"] == 500
    assert ledger["credit_shortfall_cents"] == 500

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             json_response(get(conn, "/api/v1/guests/guest-1/credit"), 200)

    assert %{"results" => [%{"refunded_cents" => 0}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "restore-shortfall",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-01-05",
                   "group_id" => "credit-target"
                 }
               ]),
               200
             )

    assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
             json_response(get(conn, "/api/v1/ledger"), 200)
  end

  test "uses the chargeback-specific rejection and payment read errors", %{conn: conn} do
    assert %{"results" => [%{"status" => "rejected", "code" => "operation_not_found"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "missing-chargeback",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => "missing-payment"
                 }
               ]),
               200
             )

    assert %{"results" => [_, %{"status" => "rejected", "code" => "payment_not_chargeable"}]} =
             json_response(
               submit(conn, [
                 open("not-a-payment"),
                 %{
                   "operation_id" => "bad-chargeback",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => "open-not-a-payment"
                 }
               ]),
               200
             )

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             json_response(get(conn, "/api/v1/payments/open-not-a-payment"), 422)
  end

  test "replays room corrections without changing their effects", %{conn: conn} do
    cancellation = %{
      "operation_id" => "durable-room-cancel",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-01-03",
      "group_id" => "durable-room-group",
      "room_ids" => ["room-a"]
    }

    assert %{"results" => [_, _, original]} =
             json_response(
               submit(conn, [
                 open("durable-room-group"),
                 %{
                   "operation_id" => "durable-room-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "durable-room-group",
                   "amount_cents" => 1_000
                 },
                 cancellation
               ]),
               200
             )

    assert %{"results" => [replayed]} = json_response(submit(conn, [cancellation]), 200)
    assert replayed == original

    assert %{"data" => %{"revision" => 3}} =
             json_response(get(conn, "/api/v1/groups/durable-room-group"), 200)
  end
end
