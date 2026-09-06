defmodule GroupStayWeb.RoomAccountingAndPaymentTest do
  use GroupStayWeb.ConnCase

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 10_000},
          %{room_id: "room-b", nightly_rate_cents: 10_000}
        ]
      },
      overrides
    )
  end

  test "allocates cash by room, reduces in reverse fill order, and reconciles the payment", %{
    conn: conn
  } do
    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        open_operation("room-accounting"),
        %{
          operation_id: "pay-room-accounting",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "room-accounting",
          amount_cents: 3_000
        }
      ]
    })
    |> json_response(200)

    assert %{
             "deposit_due_cents" => 4_000,
             "deposit_paid_cents" => 3_000,
             "rooms" => [
               %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 1_000}
             ]
           } =
             conn
             |> get("/api/v1/groups/room-accounting")
             |> json_response(200)
             |> Map.fetch!("data")

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "reduce-room-accounting",
            type: "reduce_cash_payment",
            payment_operation_id: "pay-room-accounting",
            amount_cents: 500,
            expected_revision: 2
          }
        ]
      })
      |> json_response(200)

    assert hd(response["results"]) == %{
             "operation_id" => "reduce-room-accounting",
             "status" => "applied",
             "payment_operation_id" => "pay-room-accounting",
             "group_id" => "room-accounting",
             "amount_cents" => 500,
             "outstanding_deposit_cents" => 1_500,
             "revision" => 3
           }

    assert %{"rooms" => [%{"cash_paid_cents" => 2_000}, %{"cash_paid_cents" => 500}]} =
             conn
             |> get("/api/v1/groups/room-accounting")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{
             "payment_operation_id" => "pay-room-accounting",
             "original_group_id" => "room-accounting",
             "recorded_cents" => 3_000,
             "held_cents" => 2_500,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 500,
             "charged_back_cents" => 0
           } =
             conn
             |> get("/api/v1/payments/pay-room-accounting")
             |> json_response(200)
             |> Map.fetch!("data")
  end

  test "settles selected rooms in original order and leaves other room funding active", %{
    conn: conn
  } do
    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        open_operation("selected-rooms"),
        %{
          operation_id: "pay-selected-rooms",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "selected-rooms",
          amount_cents: 3_000
        },
        %{
          operation_id: "cancel-selected-rooms",
          type: "cancel_rooms",
          occurred_on: "2026-11-20",
          group_id: "selected-rooms",
          room_ids: ["room-b", "room-a"],
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{
             "cancelled_room_ids" => ["room-a", "room-b"],
             "refunded_cents" => 3_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           } =
             conn
             |> get("/api/v1/operations/cancel-selected-rooms")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{
             "status" => "cancelled",
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "rooms" => [
               %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 2_000},
               %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 1_000}
             ]
           } =
             conn
             |> get("/api/v1/groups/selected-rooms")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 3_000} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)
             |> Map.fetch!("data")
  end

  test "partial room cancellation excludes only settled rooms from active totals", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        open_operation("partial-rooms"),
        %{
          operation_id: "pay-partial-rooms",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "partial-rooms",
          amount_cents: 3_000
        },
        %{
          operation_id: "cancel-room-a",
          type: "cancel_rooms",
          occurred_on: "2026-11-20",
          group_id: "partial-rooms",
          room_ids: ["room-a"],
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{
             "status" => "active",
             "lodging_total_cents" => 10_000,
             "deposit_due_cents" => 2_000,
             "cash_paid_cents" => 1_000,
             "outstanding_deposit_cents" => 1_000,
             "rooms" => [
               %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 2_000},
               %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 1_000}
             ]
           } =
             conn
             |> get("/api/v1/groups/partial-rooms")
             |> json_response(200)
             |> Map.fetch!("data")
  end

  test "charges back held cash and reopens the active deposit", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        open_operation("chargeback"),
        %{
          operation_id: "pay-chargeback",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "chargeback",
          amount_cents: 2_000
        },
        %{
          operation_id: "chargeback-payment",
          type: "charge_back_payment",
          payment_operation_id: "pay-chargeback",
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{
             "charged_back_cents" => 2_000,
             "outstanding_deposit_cents" => 4_000,
             "revision" => 3
           } =
             conn
             |> get("/api/v1/operations/chargeback-payment")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 2_000} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{"held_cents" => 0, "charged_back_cents" => 2_000} =
             conn
             |> get("/api/v1/payments/pay-chargeback")
             |> json_response(200)
             |> Map.fetch!("data")
  end

  test "chargeback creates a credit shortfall until applied credit is settled", %{conn: conn} do
    source =
      open_operation("shortfall-source", %{
        rooms: [%{room_id: "source", nightly_rate_cents: 10_000}]
      })

    target =
      open_operation("shortfall-target", %{
        rooms: [%{room_id: "target", nightly_rate_cents: 15_000}]
      })

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        source,
        %{
          operation_id: "pay-shortfall-source",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "shortfall-source",
          amount_cents: 2_000
        },
        %{
          operation_id: "cancel-shortfall-source",
          type: "cancel_group",
          occurred_on: "2026-11-20",
          group_id: "shortfall-source",
          refund_method: "hotel_credit"
        },
        target
      ]
    })
    |> json_response(200)

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "apply-shortfall-credit",
          type: "apply_hotel_credit",
          occurred_on: "2026-11-21",
          group_id: "shortfall-target",
          amount_cents: 1_000,
          expected_revision: 1
        },
        %{
          operation_id: "chargeback-shortfall-source",
          type: "charge_back_payment",
          payment_operation_id: "pay-shortfall-source",
          expected_revision: 3
        }
      ]
    })
    |> json_response(200)

    assert %{"credit_liability_cents" => 1_000, "credit_shortfall_cents" => 1_000} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)
             |> Map.fetch!("data")
  end
end
