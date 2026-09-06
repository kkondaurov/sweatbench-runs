defmodule GroupStayWeb.Acceptance.ChargeBackPaymentTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # One room over two nights (flexible, 20% deposit): deposit 4000.
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  # Two rooms so payments can exceed one room's deposit when needed.
  defp open_two_room_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000}
        ]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp charge_back_op(op_id, payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp cancel_op(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp apply_credit_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, on) do
    conn
    |> get("/api/v1/guests/#{@guest}/credit", %{"on" => on})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "charging back held cash" do
    test "reverses held cash on an active group and reopens the deposit" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

      assert [
               %{
                 "operation_id" => "cb-1",
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-a",
                 "charged_back_cents" => 3000,
                 "outstanding_deposit_cents" => 4000,
                 "revision" => 3
               }
             ] = submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      group = group(build_conn(), "group-a")
      assert group["status"] == "active"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 4000

      assert ledger(build_conn())["cash_held_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 3000
    end
  end

  describe "charging back settled cash" do
    test "reclassifies refunded cash on a cancelled group" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])
      submit(build_conn(), [cancel_op("group-a", "2026-11-01")])

      assert ledger(build_conn())["cash_refunded_cents"] == 3000

      assert [%{"status" => "applied", "charged_back_cents" => 3000}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert ledger(build_conn())["cash_refunded_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 3000
    end

    test "reclassifies retained cash on a non-refundable cancellation" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])
      submit(build_conn(), [cancel_op("group-a", "2026-12-05")])

      assert ledger(build_conn())["cash_retained_cents"] == 3000

      assert [%{"status" => "applied", "charged_back_cents" => 3000}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert ledger(build_conn())["cash_retained_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 3000
    end

    test "reverses both settled and still-held portions of one payment" do
      # pay-1 fills room-a (4000) and part of room-b (2000).
      submit(build_conn(), [open_two_room_op("group-a"), pay_op("pay-1", "group-a", 6000)])

      # Cancelling room-a refundably settles its 4000; room-b's 2000 stays held.
      submit(build_conn(), [
        %{
          "operation_id" => "cancel-rooms-a",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-a",
          "room_ids" => ["room-a"]
        }
      ])

      assert ledger(build_conn())["cash_refunded_cents"] == 4000
      assert ledger(build_conn())["cash_held_cents"] == 2000

      assert [%{"status" => "applied", "charged_back_cents" => 6000}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert ledger(build_conn())["cash_refunded_cents"] == 0
      assert ledger(build_conn())["cash_held_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 6000

      # Removing the held portion reopens room-b's outstanding deposit.
      group = group(build_conn(), "group-a")
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 6000
    end

    test "chargeback of a cancelled group's payment increments that group's revision once" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])
      submit(build_conn(), [cancel_op("group-a", "2026-11-01")])

      assert group(build_conn(), "group-a")["revision"] == 3

      assert [%{"status" => "applied", "revision" => 4}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert group(build_conn(), "group-a")["revision"] == 4
    end
  end

  describe "charging back converted cash and credit entitlement" do
    test "revokes unspent entitlement from the lot without shortfall" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 4000)])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      # 4000 cash -> 4400 lot.
      assert guest_credit(build_conn(), "2026-11-01")["available_cents"] == 4400
      assert ledger(build_conn())["cash_converted_to_credit_cents"] == 4000

      assert [%{"status" => "applied", "charged_back_cents" => 4000}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      # The whole 4400 entitlement is removed from the lot.
      assert guest_credit(build_conn(), "2026-11-01")["available_cents"] == 0
      assert ledger(build_conn())["cash_converted_to_credit_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 4000
      assert ledger(build_conn())["credit_shortfall_cents"] == 0
      assert ledger(build_conn())["credit_liability_cents"] == 0
    end

    test "an entitlement that cannot be removed becomes the lot's shortfall" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 4000)])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      # Spend 3000 of the 4400 lot on another group, leaving 1400.
      submit(build_conn(), [open_op("group-b")])
      submit(build_conn(), [apply_credit_op("credit-b", "group-b", 3000)])

      assert guest_credit(build_conn(), "2026-11-02")["available_cents"] == 1400

      assert [%{"status" => "applied", "charged_back_cents" => 4000}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      # 1400 removed from the lot, 3000 cannot be removed -> shortfall.
      assert guest_credit(build_conn(), "2026-11-02")["available_cents"] == 0
      assert ledger(build_conn())["credit_shortfall_cents"] == 3000
      # Liability still includes the 3000 applied to the active group.
      assert ledger(build_conn())["credit_liability_cents"] == 3000

      # The funded group's revision and state are untouched.
      assert group(build_conn(), "group-b")["revision"] == 2
      assert group(build_conn(), "group-b")["status"] == "active"
    end

    test "non-refundable settlement of the credit extinguishes the shortfall" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 4000)])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [open_op("group-b")])
      submit(build_conn(), [apply_credit_op("credit-b", "group-b", 3000)])
      submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert ledger(build_conn())["credit_shortfall_cents"] == 3000

      # Non-refundably settling group-b consumes the applied credit.
      submit(build_conn(), [cancel_op("group-b", "2026-12-05")])

      assert ledger(build_conn())["credit_shortfall_cents"] == 0
      assert ledger(build_conn())["credit_liability_cents"] == 0
    end

    test "a restoration is absorbed by the shortfall before becoming available" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 4000)])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [open_op("group-b")])
      submit(build_conn(), [apply_credit_op("credit-b", "group-b", 3000)])
      submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert ledger(build_conn())["credit_shortfall_cents"] == 3000

      # Refundably cancelling group-b restores the 3000; it is absorbed by the
      # unrecovered clawback rather than becoming available.
      submit(build_conn(), [cancel_op("group-b", "2026-11-20")])

      assert guest_credit(build_conn(), "2026-11-20")["available_cents"] == 0
      assert ledger(build_conn())["credit_shortfall_cents"] == 0
      assert ledger(build_conn())["credit_liability_cents"] == 0
    end

    test "entitlements telescope when several payments fund one lot" do
      submit(build_conn(), [
        open_two_room_op("group-a"),
        pay_op("pay-1", "group-a", 1000),
        pay_op("pay-2", "group-a", 1000)
      ])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      # 2000 cash -> 2200 lot.
      assert guest_credit(build_conn(), "2026-11-01")["available_cents"] == 2200

      # pay-1 entitlement: bonusValue(1000) - bonusValue(0) = 1100.
      assert [%{"status" => "applied", "charged_back_cents" => 1000}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert guest_credit(build_conn(), "2026-11-01")["available_cents"] == 1100

      # pay-2 entitlement: bonusValue(2000) - bonusValue(1000) = 1100.
      assert [%{"status" => "applied", "charged_back_cents" => 1000}] =
               submit(build_conn(), [charge_back_op("cb-2", "pay-2")])

      assert guest_credit(build_conn(), "2026-11-01")["available_cents"] == 0
      assert ledger(build_conn())["credit_shortfall_cents"] == 0
    end
  end

  describe "rejections" do
    test "operation_not_found when no durable record exists" do
      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(build_conn(), [charge_back_op("cb-1", "never-seen")])
    end

    test "payment_not_chargeable for a non-payment operation" do
      submit(build_conn(), [open_op("group-a")])

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(build_conn(), [charge_back_op("cb-1", "open-group-a")])
    end

    test "payment_not_chargeable for a rejected payment" do
      submit(build_conn(), [open_op("group-a")])
      submit(build_conn(), [pay_op("pay-bad", "group-a", 0)])

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-bad")])
    end

    test "payment_not_chargeable for a fully reduced payment" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

      submit(build_conn(), [
        %{
          "operation_id" => "reduce-1",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-1",
          "amount_cents" => 3000
        }
      ])

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(build_conn(), [charge_back_op("cb-1", "pay-1")])
    end

    test "payment_not_chargeable when already charged back" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])
      submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(build_conn(), [charge_back_op("cb-2", "pay-1")])
    end

    test "follows the revision contract against the payment's group" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

      assert [%{"status" => "applied", "revision" => 3}] =
               submit(build_conn(), [
                 charge_back_op("cb-1", "pay-1", %{
                   "expected_revision" => 2
                 })
               ])
    end
  end

  describe "durability" do
    test "a retry returns the stored result without reapplying" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

      [first] = submit(build_conn(), [charge_back_op("cb-1", "pay-1")])
      assert first["status"] == "applied"

      assert submit(build_conn(), [charge_back_op("cb-1", "pay-1")]) == [first]

      assert ledger(build_conn())["cash_charged_back_cents"] == 3000
      assert group(build_conn(), "group-a")["revision"] == 3
    end

    test "never rewrites the original payment's stored result" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])
      [payment_result] = submit(build_conn(), [pay_op("pay-1", "group-a", 3000)])

      submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      assert submit(build_conn(), [pay_op("pay-1", "group-a", 3000)]) == [payment_result]
    end
  end
end
