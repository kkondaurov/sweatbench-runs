defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  describe "room accounting and payment reductions" do
    test "allocates funding in room order, settles selected rooms, and reconciles reductions", %{
      conn: conn
    } do
      submit(conn, [
        open_group(),
        payment("pay-room", "room-group", 150),
        %{
          "operation_id" => "cancel-second-room",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "room-group",
          "room_ids" => ["room-b"],
          "expected_revision" => 2
        },
        %{
          "operation_id" => "reduce-room-payment",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "pay-room",
          "amount_cents" => 50,
          "expected_revision" => 3
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{"revision" => 1},
                   %{"revision" => 2},
                   %{
                     "status" => "applied",
                     "cancelled_room_ids" => ["room-b"],
                     "refunded_cents" => 50,
                     "retained_cents" => 0,
                     "revision" => 3
                   },
                   %{
                     "status" => "applied",
                     "amount_cents" => 50,
                     "outstanding_deposit_cents" => 50,
                     "revision" => 4
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 500,
                 "deposit_due_cents" => 100,
                 "cash_paid_cents" => 50,
                 "outstanding_deposit_cents" => 50,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "active",
                     "deposit_due_cents" => 100,
                     "cash_paid_cents" => 50
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "cancelled",
                     "deposit_due_cents" => 200,
                     "cash_paid_cents" => 0
                   }
                 ]
               }
             } = get(build_conn(), "/api/v1/groups/room-group") |> json_response(200)

      assert %{
               "data" => %{
                 "payment_operation_id" => "pay-room",
                 "original_group_id" => "room-group",
                 "recorded_cents" => 150,
                 "held_cents" => 50,
                 "refunded_cents" => 50,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 50,
                 "charged_back_cents" => 0
               }
             } = get(build_conn(), "/api/v1/payments/pay-room") |> json_response(200)

      assert %{"data" => %{"cash_reduced_cents" => 50, "cash_refunded_cents" => 50}} =
               get(build_conn(), "/api/v1/ledger") |> json_response(200)

      submit(build_conn(), [
        %{
          "operation_id" => "charge-back-room-payment",
          "type" => "charge_back_payment",
          "payment_operation_id" => "pay-room",
          "expected_revision" => 4
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "status" => "applied",
                     "charged_back_cents" => 100,
                     "outstanding_deposit_cents" => 100,
                     "revision" => 5
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "reduced_cents" => 50,
                 "charged_back_cents" => 100
               }
             } = get(build_conn(), "/api/v1/payments/pay-room") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_reduced_cents" => 50,
                 "cash_charged_back_cents" => 100
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "revokes converted-credit entitlement and absorbs a later refundable restoration", %{
      conn: conn
    } do
      submit(conn, [
        open_group(%{
          "operation_id" => "open-source",
          "group_id" => "source",
          "guest_id" => "credit-guest"
        }),
        payment("source-payment", "source", 100),
        %{
          "operation_id" => "source-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        },
        open_group(%{
          "operation_id" => "open-target",
          "group_id" => "target",
          "guest_id" => "credit-guest"
        }),
        %{
          "operation_id" => "apply-source-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-02",
          "group_id" => "target",
          "amount_cents" => 110
        },
        %{
          "operation_id" => "charge-back-source-payment",
          "type" => "charge_back_payment",
          "payment_operation_id" => "source-payment",
          "expected_revision" => 3
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{},
                   %{},
                   %{"credit_issued_cents" => 110},
                   %{},
                   %{"status" => "applied", "revision" => 2},
                   %{
                     "status" => "applied",
                     "group_id" => "source",
                     "charged_back_cents" => 100,
                     "revision" => 4
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 100,
                 "credit_liability_cents" => 110,
                 "credit_shortfall_cents" => 110
               }
             } = get(build_conn(), "/api/v1/ledger?on=2026-11-02") |> json_response(200)

      submit(build_conn(), [
        %{
          "operation_id" => "cancel-credit-target",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-03",
          "group_id" => "target",
          "expected_revision" => 2
        }
      ])

      assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
               get(build_conn(), "/api/v1/ledger?on=2026-11-03") |> json_response(200)
    end

    test "distinguishes unknown and non-reconcilable payment reads", %{conn: conn} do
      assert %{"error" => %{"code" => "operation_not_found"}} =
               get(conn, "/api/v1/payments/missing") |> json_response(404)

      submit(build_conn(), [
        open_group(%{"operation_id" => "not-a-payment", "group_id" => "other"})
      ])

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
               get(build_conn(), "/api/v1/payments/not-a-payment") |> json_response(422)
    end
  end

  defp open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-room-group",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "room-group",
        "guest_id" => "room-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 500},
          %{"room_id" => "room-b", "nightly_rate_cents" => 1000}
        ]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end
end
