defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  describe "room allocation and selected cancellation" do
    test "funds in room order and settles selected rooms atomically", %{conn: conn} do
      operations = [
        open_operation("open-rooms", "rooms-group", [500, 500]),
        payment_operation("pay-rooms", "rooms-group", 150),
        %{
          "operation_id" => "cancel-room-b",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-02-01",
          "group_id" => "rooms-group",
          "room_ids" => ["room-b"]
        }
      ]

      assert %{"results" => [_, _, cancelled]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled == %{
               "operation_id" => "cancel-room-b",
               "status" => "applied",
               "group_id" => "rooms-group",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 50,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 500,
                 "deposit_due_cents" => 100,
                 "deposit_paid_cents" => 100,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "active",
                     "lodging_total_cents" => 500,
                     "deposit_due_cents" => 100,
                     "cash_paid_cents" => 100,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "cancelled",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = get_group("rooms-group")

      invalid = %{
        "operation_id" => "invalid-room-list",
        "type" => "cancel_rooms",
        "occurred_on" => "2027-02-01",
        "group_id" => "rooms-group",
        "room_ids" => ["room-a", "room-a"]
      }

      assert %{"results" => [%{"code" => "invalid_rooms"}]} =
               build_conn() |> post_batch([invalid]) |> json_response(200)

      assert %{"data" => %{"revision" => 3}} = get_group("rooms-group")
    end

    test "returns cancelled room identifiers in original order and cancels the group", %{
      conn: conn
    } do
      operations = [
        open_operation("open-order", "order-group", [500, 500]),
        %{
          "operation_id" => "cancel-order",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-02-01",
          "group_id" => "order-group",
          "room_ids" => ["room-b", "room-a"]
        }
      ]

      assert %{"results" => [_, cancelled]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled["cancelled_room_ids"] == ["room-a", "room-b"]

      assert %{"data" => %{"status" => "cancelled", "deposit_due_cents" => 0}} =
               get_group("order-group")
    end
  end

  describe "cash payment corrections" do
    test "reduces only the target payment in reverse fill order and reconciles it", %{conn: conn} do
      payment = payment_operation("pay-reduce", "reduce-group", 150)

      assert %{"results" => [_, original]} =
               conn
               |> post_batch([open_operation("open-reduce", "reduce-group", [500, 500]), payment])
               |> json_response(200)

      reduction = %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2027-01-03",
        "payment_operation_id" => "pay-reduce",
        "amount_cents" => 60,
        "expected_revision" => 2
      }

      assert %{"results" => [reduced]} =
               build_conn() |> post_batch([reduction]) |> json_response(200)

      assert reduced == %{
               "operation_id" => "reduce-1",
               "status" => "applied",
               "payment_operation_id" => "pay-reduce",
               "group_id" => "reduce-group",
               "amount_cents" => 60,
               "outstanding_deposit_cents" => 110,
               "revision" => 3
             }

      assert %{"data" => %{"rooms" => [first, second]}} = get_group("reduce-group")
      assert first["cash_paid_cents"] == 90
      assert second["cash_paid_cents"] == 0

      assert get_payment("pay-reduce") == %{
               "data" => %{
                 "payment_operation_id" => "pay-reduce",
                 "original_group_id" => "reduce-group",
                 "recorded_cents" => 150,
                 "held_cents" => 90,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 60,
                 "charged_back_cents" => 0
               }
             }

      assert build_conn() |> post_batch([reduction]) |> json_response(200) == %{
               "results" => [reduced]
             }

      assert build_conn() |> post_batch([payment]) |> json_response(200) == %{
               "results" => [original]
             }

      assert %{"data" => %{"cash_held_cents" => 90, "cash_reduced_cents" => 60}} =
               get_ledger()
    end

    test "uses the specified reduction rejection taxonomy", %{conn: conn} do
      assert %{"results" => [_, _]} =
               conn
               |> post_batch([
                 open_operation("open-errors", "error-group", [500]),
                 payment_operation("pay-errors", "error-group", 50)
               ])
               |> json_response(200)

      attempts = [
        reduction_operation("missing-target", "no-such-operation", 1),
        reduction_operation("wrong-target", "open-errors", 1),
        reduction_operation("zero-reduction", "pay-errors", 0),
        reduction_operation("large-reduction", "pay-errors", 51)
      ]

      assert %{"results" => results} =
               build_conn() |> post_batch(attempts) |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "operation_not_found",
               "payment_not_reducible",
               "invalid_amount",
               "reduction_exceeds_held_cash"
             ]
    end
  end

  describe "chargebacks and credit clawbacks" do
    test "reclassifies payment cash and reports then absorbs a credit shortfall", %{conn: conn} do
      setup = [
        open_operation("open-source", "source-group", [500, 500]),
        payment_operation("pay-source", "source-group", 150),
        %{
          "operation_id" => "convert-room",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-02-01",
          "group_id" => "source-group",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        },
        open_operation("open-credit-target", "credit-target", [1_000]),
        %{
          "operation_id" => "apply-converted",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-02-02",
          "group_id" => "credit-target",
          "amount_cents" => 110
        }
      ]

      assert %{"results" => [_, _, converted, _, _]} =
               conn |> post_batch(setup) |> json_response(200)

      assert converted["credit_issued_cents"] == 110

      chargeback = %{
        "operation_id" => "chargeback-source",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-02-03",
        "payment_operation_id" => "pay-source",
        "expected_revision" => 3
      }

      assert %{"results" => [charged]} =
               build_conn() |> post_batch([chargeback]) |> json_response(200)

      assert charged == %{
               "operation_id" => "chargeback-source",
               "status" => "applied",
               "payment_operation_id" => "pay-source",
               "group_id" => "source-group",
               "charged_back_cents" => 150,
               "outstanding_deposit_cents" => 100,
               "revision" => 4
             }

      assert %{"data" => %{"revision" => 2}} = get_group("credit-target")

      assert %{
               "data" => %{
                 "recorded_cents" => 150,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 150
               }
             } = get_payment("pay-source")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 150,
                 "credit_liability_cents" => 110,
                 "credit_shortfall_cents" => 110
               }
             } = get_ledger()

      cancel_target = %{
        "operation_id" => "cancel-credit-target",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-04",
        "group_id" => "credit-target"
      }

      assert %{"results" => [%{"status" => "applied"}]} =
               build_conn() |> post_batch([cancel_target]) |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
               get_ledger()
    end

    test "telescopes half-up bonus entitlement independently within a credit lot", %{conn: conn} do
      operations = [
        open_operation("open-rounding-source", "rounding-source", [50]),
        payment_operation("rounding-pay-1", "rounding-source", 5),
        payment_operation("rounding-pay-2", "rounding-source", 5),
        %{
          "operation_id" => "rounding-conversion",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-01",
          "group_id" => "rounding-source",
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "charge-second-rounding-payment",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-02-02",
          "payment_operation_id" => "rounding-pay-2"
        }
      ]

      assert %{"results" => [_, _, _, converted, charged]} =
               conn |> post_batch(operations) |> json_response(200)

      assert converted["credit_issued_cents"] == 11
      assert charged["charged_back_cents"] == 5

      assert build_conn()
             |> get("/api/v1/guests/guest-room-accounting/credit?on=2027-02-02")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => "guest-room-accounting",
                 "available_cents" => 6,
                 "lots" => [
                   %{
                     "source_operation_id" => "rounding-conversion",
                     "remaining_cents" => 6,
                     "expires_on" => "2028-02-01"
                   }
                 ]
               }
             }
    end
  end

  describe "payment read errors" do
    test "distinguishes missing and non-reconcilable operations", %{conn: conn} do
      assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert %{"results" => [_]} =
               build_conn()
               |> post_batch([open_operation("not-a-payment", "read-error-group", [500])])
               |> json_response(200)

      assert build_conn() |> get("/api/v1/payments/not-a-payment") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp get_group(group_id),
    do: build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)

  defp get_payment(operation_id),
    do: build_conn() |> get("/api/v1/payments/#{operation_id}") |> json_response(200)

  defp get_ledger,
    do: build_conn() |> get("/api/v1/ledger?on=2027-02-04") |> json_response(200)

  defp open_operation(operation_id, group_id, rates) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-room-accounting",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-12-01",
      "departure_on" => "2027-12-02",
      "rate_plan" => "flexible",
      "rooms" =>
        rates
        |> Enum.with_index()
        |> Enum.map(fn {rate, index} ->
          %{"room_id" => "room-#{<<97 + index>>}", "nightly_rate_cents" => rate}
        end)
    }
  end

  defp payment_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp reduction_operation(operation_id, target, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-03",
      "payment_operation_id" => target,
      "amount_cents" => amount
    }
  end
end
