defmodule GroupStayWeb.ChargeBackPaymentTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp charge_back_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-charge-back",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp charge_back(conn, overrides \\ %{}) do
    %{"results" => [result]} = submit_batch(conn, [charge_back_op(overrides)])
    result
  end

  defp pay(conn, amount_cents, overrides \\ %{}) do
    pay_group(
      conn,
      "group-81",
      amount_cents,
      Map.merge(%{"operation_id" => "op-pay"}, overrides)
    )
  end

  defp open_second_group(conn) do
    open_group_fixture(conn, %{
      "operation_id" => "op-open-82",
      "group_id" => "group-82",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-23"
    })
  end

  defp apply_credit_to_second_group(conn, amount_cents) do
    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-apply-82",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-82",
          "amount_cents" => amount_cents
        }
      ])

    result
  end

  describe "reclassifying dispositions" do
    test "removes held cash and reopens the outstanding deposit", %{conn: conn} do
      pay(conn, 5000)

      result = charge_back(conn)

      assert result == %{
               "operation_id" => "op-charge-back",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 5000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 3
             }

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000

      assert group_data(conn, "group-81")["cash_paid_cents"] == 0
    end

    test "moves refunded cash to charged-back cash", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26")

      result = charge_back(conn)

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5000
      assert result["outstanding_deposit_cents"] == 0

      ledger = ledger_data(conn)
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
      assert ledger["cash_held_cents"] == 0
    end

    test "moves retained cash to charged-back cash", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-27")

      result = charge_back(conn)

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5000

      ledger = ledger_data(conn)
      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "moves converted principal and revokes the entitlement it created", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500

      result = charge_back(conn)

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5000

      ledger = ledger_data(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5000
      assert ledger["credit_shortfall_cents"] == 0

      # The 500 bonus entitlement is removed from the lot's remaining balance.
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5000
    end

    test "excludes portions already recorded as reduced", %{conn: conn} do
      pay(conn, 5000)

      submit_batch(conn, [
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-10",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 2000
        }
      ])

      result = charge_back(conn)

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 3000

      ledger = ledger_data(conn)
      assert ledger["cash_reduced_cents"] == 2000
      assert ledger["cash_charged_back_cents"] == 3000
      assert ledger["cash_held_cents"] == 0
    end
  end

  describe "entitlement attribution" do
    test "assigns entitlement in funding order across payments", %{conn: conn} do
      pay(conn, 3000)
      pay(conn, 2000, %{"operation_id" => "op-pay-2"})

      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500

      first = charge_back(conn)
      assert first["status"] == "applied"
      # The 10% bonus value of the first 3000 settled.
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5200

      second =
        charge_back(conn, %{
          "operation_id" => "op-charge-back-2",
          "payment_operation_id" => "op-pay-2"
        })

      assert second["status"] == "applied"
      # round(10% of 5000) - round(10% of 3000) = 500 - 300.
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5000

      assert ledger_data(conn)["cash_charged_back_cents"] == 5000
      assert ledger_data(conn)["credit_shortfall_cents"] == 0
    end

    test "applies the rounding rule to both running totals", %{conn: conn} do
      # 10% of 1005 rounds up to 101; 10% of 2005 rounds up to 201, so the
      # second payment's entitlement is 100.
      pay(conn, 1005)
      pay(conn, 1000, %{"operation_id" => "op-pay-2"})

      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 2206

      charge_back(conn)
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 2105

      charge_back(conn, %{
        "operation_id" => "op-charge-back-2",
        "payment_operation_id" => "op-pay-2"
      })

      assert guest_credit_data(conn, "guest-22")["available_cents"] == 2005
    end

    test "computes entitlements independently for each lot the payment contributed to", %{
      conn: conn
    } do
      # The single payment funds both rooms, which are cancelled separately.
      pay(conn, 10000)

      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-a",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        }
      ])

      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-b",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "room_ids" => ["room-b"],
          "refund_method" => "hotel_credit"
        }
      ])

      # Lots of 9900 (room-a's 9000) and 1100 (room-b's 1000).
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 11000

      result = charge_back(conn)

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10000

      # Each lot loses its own bonus value: 900 and 100.
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 10000
      assert ledger_data(conn)["credit_shortfall_cents"] == 0
    end
  end

  describe "credit shortfall" do
    test "unrecoverable entitlement becomes the lot's shortfall", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      open_second_group(conn)
      assert apply_credit_to_second_group(conn, 5500)["status"] == "applied"
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 0

      result = charge_back(conn)

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5000

      ledger = ledger_data(conn)
      # The 500 entitlement cannot be removed from the spent lot.
      assert ledger["credit_shortfall_cents"] == 500
      # Liability still includes the applied credit covered by the shortfall.
      assert ledger["credit_liability_cents"] == 5500
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 0
    end

    test "non-refundable settlement of the credit reduces the shortfall", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      open_second_group(conn)
      apply_credit_to_second_group(conn, 5500)
      charge_back(conn)
      assert ledger_data(conn)["credit_shortfall_cents"] == 500

      # Inside group-82's refund window credit is consumed, not restored.
      cancel_group(conn, "group-82", "2026-12-09")

      ledger = ledger_data(conn)
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end

    test "restored credit extinguishes unrecovered clawback before becoming available", %{
      conn: conn
    } do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      open_second_group(conn)
      apply_credit_to_second_group(conn, 5500)
      charge_back(conn)
      assert ledger_data(conn)["credit_shortfall_cents"] == 500

      # A refundable cancellation restores the 5500: 500 extinguishes the
      # clawback and the remaining 5000 becomes available again.
      cancel_group(conn, "group-82", "2026-11-30")

      ledger = ledger_data(conn)
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 5000
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5000
    end

    test "absorption occurs before checking the lot's expiry", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-old",
        "group_id" => "group-old",
        "occurred_on" => "2024-12-01",
        "arrival_on" => "2025-02-10",
        "departure_on" => "2025-02-13"
      })

      pay_group(conn, "group-old", 5000, %{"operation_id" => "op-pay-old"})

      cancel_group(conn, "group-old", "2025-01-01", %{"refund_method" => "hotel_credit"})

      open_second_group(conn)

      %{"results" => [applied]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-apply-82",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2025-01-02",
            "group_id" => "group-82",
            "amount_cents" => 5500
          }
        ])

      assert applied["status"] == "applied"

      %{"results" => [charged]} =
        submit_batch(conn, [charge_back_op(%{"payment_operation_id" => "op-pay-old"})])

      assert charged["status"] == "applied"
      assert ledger_data(conn)["credit_shortfall_cents"] == 500

      # The lot expired on 2026-01-01; restoring on 2026-02-01 absorbs the
      # clawback first and the excess expires.
      cancel_group(conn, "group-82", "2026-02-01")

      ledger = ledger_data(conn)
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 0
    end
  end

  describe "rejections" do
    test "rejects operation_not_found when no durable record exists", %{conn: conn} do
      result = charge_back(conn, %{"payment_operation_id" => "op-missing"})

      assert result["status"] == "rejected"
      assert result["code"] == "operation_not_found"
    end

    test "rejects payment_not_chargeable for a non-payment record", %{conn: conn} do
      result = charge_back(conn, %{"payment_operation_id" => "op-1001"})

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"
    end

    test "rejects payment_not_chargeable for a rejected payment", %{conn: conn} do
      pay(conn, 999_999)

      result = charge_back(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"
    end

    test "rejects payment_not_chargeable for a fully reduced payment", %{conn: conn} do
      pay(conn, 5000)

      submit_batch(conn, [
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-10",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 5000
        }
      ])

      result = charge_back(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"
    end

    test "rejects payment_not_chargeable when already charged back", %{conn: conn} do
      pay(conn, 5000)
      assert charge_back(conn)["status"] == "applied"

      result = charge_back(conn, %{"operation_id" => "op-charge-back-2"})

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"

      assert ledger_data(conn)["cash_charged_back_cents"] == 5000
    end

    test "rejects a stale revision before chargeability checks", %{conn: conn} do
      pay(conn, 5000)

      result = charge_back(conn, %{"expected_revision" => 7})

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["expected_revision"] == 7
      assert result["actual_revision"] == 2
    end
  end

  describe "scope and durability" do
    test "increments only the original payment group's revision", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      open_second_group(conn)
      apply_credit_to_second_group(conn, 5500)

      charge_back(conn)

      assert group_data(conn, "group-81")["revision"] == 4
      # The group funded by the credit is untouched.
      assert group_data(conn, "group-82")["revision"] == 2
      assert group_data(conn, "group-82")["status"] == "active"
      assert group_data(conn, "group-82")["credit_paid_cents"] == 5500
    end

    test "never rewrites the original payment's stored result", %{conn: conn} do
      %{"results" => [original]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      charge_back(conn)

      %{"results" => [retry]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert retry == original

      conn = get(conn, ~p"/api/v1/operations/op-pay")
      assert json_response(conn, 200) == %{"data" => original}
    end

    test "a chargeback is durably idempotent", %{conn: conn} do
      pay(conn, 5000)

      %{"results" => [first]} = submit_batch(conn, [charge_back_op()])
      %{"results" => [retry]} = submit_batch(conn, [charge_back_op()])

      assert retry == first
      assert ledger_data(conn)["cash_charged_back_cents"] == 5000
      assert group_data(conn, "group-81")["revision"] == 3
    end

    test "works whether the group is active or cancelled", %{conn: conn} do
      pay(conn, 5000)
      assert charge_back(conn)["status"] == "applied"

      pay(conn, 4000, %{"operation_id" => "op-pay-2"})
      cancel_group(conn, "group-81", "2026-11-26")

      result =
        charge_back(conn, %{
          "operation_id" => "op-charge-back-2",
          "payment_operation_id" => "op-pay-2"
        })

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 4000
    end
  end
end
