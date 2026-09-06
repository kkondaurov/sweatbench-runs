defmodule GroupStayWeb.PaymentReductionsTest do
  @moduledoc """
  End-to-end coverage of the reduce_cash_payment and charge_back_payment
  operations: the dispositions they move cash through, the ledger and group
  views they keep consistent, and the rejection codes they use.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  @zeroed %{
    "cash_held_cents" => 0,
    "cash_refunded_cents" => 0,
    "cash_retained_cents" => 0,
    "cash_converted_to_credit_cents" => 0,
    "cash_reduced_cents" => 0,
    "cash_charged_back_cents" => 0,
    "credit_liability_cents" => 0,
    "credit_shortfall_cents" => 0
  }

  defp ledger(on \\ "2026-12-01"), do: json_response(get_ledger(on), 200)["data"]

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          reduce_cash_operation("op-3", "op-2", 4_000, %{"occurred_on" => "2026-11-20"})
        ])

      assert results(conn) == [
               %{
                 "operation_id" => "op-3",
                 "status" => "applied",
                 "payment_operation_id" => "op-2",
                 "group_id" => "group-81",
                 "amount_cents" => 4_000,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 3
               }
             ]

      data = json_response(get_group("group-81"), 200)["data"]

      assert data["deposit_paid_cents"] == 8_000
      assert data["outstanding_deposit_cents"] == 11_500

      # room-b's 3_000 was removed first, then 1_000 from room-a
      assert Enum.map(data["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
               [{"room-a", 8_000}, {"room-b", 0}]

      assert ledger() == %{@zeroed | "cash_held_cents" => 8_000, "cash_reduced_cents" => 4_000}

      assert json_response(get_payment("op-2"), 200)["data"] == %{
               "payment_operation_id" => "op-2",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 8_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 4_000,
               "charged_back_cents" => 0
             }
    end

    test "successive reductions compose against the remaining held cash" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          reduce_cash_operation("op-3", "op-2", 4_000),
          reduce_cash_operation("op-4", "op-2", 500)
        ])

      assert Enum.map(results(conn), & &1["outstanding_deposit_cents"]) == [11_500, 12_000]

      # an amount equal to the complete remaining held portion is valid
      conn = post_batch([reduce_cash_operation("op-5", "op-2", 7_500)])
      assert hd(results(conn))["status"] == "applied"

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 19_500
      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [0, 0]

      # with no held cash left, the payment can never accept another reduction
      conn = post_batch([reduce_cash_operation("op-6", "op-2", 1)])
      assert hd(results(conn))["code"] == "payment_not_reducible"

      assert ledger() == %{@zeroed | "cash_reduced_cents" => 12_000}
    end

    test "rejects a reduction exceeding the payment's currently held cash" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn = post_batch([reduce_cash_operation("op-3", "op-2", 12_001)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "reduction_exceeds_held_cash",
               "group_id" => "group-81"
             }

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["deposit_paid_cents"] == 12_000
      assert data["revision"] == 2
    end

    test "rejects unusable amounts" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      for {amount, n} <- Enum.with_index([0, -100, "4000", nil, 50.5]) do
        conn = post_batch([reduce_cash_operation("op-#{n + 3}", "op-2", amount)])
        assert hd(results(conn))["code"] == "invalid_amount", inspect(amount)
      end
    end

    test "rejects targets that can never accept a positive reduction" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 12_000),
        # a rejected payment has no applied result
        pay_operation("op-rejected", "group-81", 99_999),
        # a settled payment holds no cash on active rooms
        cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-20"}),
        # a credit application is not a cash payment
        apply_credit_operation("op-4", "group-81", 100)
      ])

      cases = [
        {"unknown operation", "op-none", "operation_not_found"},
        {"non-payment operation", "op-1", "payment_not_reducible"},
        {"rejected payment", "op-rejected", "payment_not_reducible"},
        {"settled payment", "op-2", "payment_not_reducible"},
        {"credit application", "op-4", "payment_not_reducible"}
      ]

      for {{label, target, code}, n} <- Enum.with_index(cases) do
        conn = post_batch([reduce_cash_operation("op-#{n + 10}", target, 100)])
        result = hd(results(conn))
        assert result["code"] == code, label
        assert result["status"] == "rejected", label
      end
    end

    test "rejects an operation missing the data it needs" do
      conn =
        post_batch([
          %{
            "operation_id" => "op-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-11-20",
            "amount_cents" => 100
          }
        ])

      assert hd(results(conn))["code"] == "invalid_operation"
    end

    test "never rewrites the target payment's stored result" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      original = hd(results(post_batch([pay_operation("op-2", "group-81", 12_000)])))

      post_batch([reduce_cash_operation("op-3", "op-2", 4_000)])

      # retrying the original payment returns its exact original result
      # without reapplying cash
      assert results(post_batch([pay_operation("op-2", "group-81", 12_000)])) == [original]

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["deposit_paid_cents"] == 8_000
      assert data["revision"] == 3
    end

    test "follows the revision contract against the payment's group" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          reduce_cash_operation("op-3", "op-2", 4_000, %{"expected_revision" => 1})
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn =
        post_batch([
          reduce_cash_operation("op-4", "op-2", 4_000, %{"expected_revision" => 2})
        ])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 3
    end

    test "is durably idempotent" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      operation = reduce_cash_operation("op-3", "op-2", 4_000)
      original = hd(results(post_batch([operation])))
      assert results(post_batch([operation])) == [original]

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["deposit_paid_cents"] == 8_000
      assert data["revision"] == 3
    end

    test "a reduced payment settles only its remaining held cash later" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 12_000),
        reduce_cash_operation("op-3", "op-2", 4_000),
        cancel_operation("op-4", "group-81", %{"occurred_on" => "2026-11-20"})
      ])

      # recorded cash equals held plus refunded, retained, converted, and reduced
      assert ledger() == %{
               @zeroed
               | "cash_refunded_cents" => 8_000,
                 "cash_reduced_cents" => 4_000
             }

      assert json_response(get_payment("op-2"), 200)["data"] == %{
               "payment_operation_id" => "op-2",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 0,
               "refunded_cents" => 8_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 4_000,
               "charged_back_cents" => 0
             }
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash of an active group and reopens its deposit" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 12_000)])

      conn =
        post_batch([
          charge_back_operation("op-3", "op-2", %{"occurred_on" => "2026-11-20"})
        ])

      assert results(conn) == [
               %{
                 "operation_id" => "op-3",
                 "status" => "applied",
                 "payment_operation_id" => "op-2",
                 "group_id" => "group-81",
                 "charged_back_cents" => 12_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               }
             ]

      data = json_response(get_group("group-81"), 200)["data"]

      assert data["status"] == "active"
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 19_500

      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 12_000}
    end

    test "reclassifies refunded cash of a cancelled group" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-20"})
      ])

      conn = post_batch([charge_back_operation("op-4", "op-2")])

      assert hd(results(conn)) == %{
               "operation_id" => "op-4",
               "status" => "applied",
               "payment_operation_id" => "op-2",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      # the classification changes, but the historical refund is not reissued
      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 10_000}

      assert json_response(get_payment("op-2"), 200)["data"] == %{
               "payment_operation_id" => "op-2",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 10_000
             }
    end

    test "reverses all cash except a reduced portion" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        reduce_cash_operation("op-3", "op-2", 4_000),
        charge_back_operation("op-4", "op-2")
      ])

      conn = post_batch([charge_back_operation("op-4", "op-2")])
      original = result_for(conn, "op-4")

      assert original["charged_back_cents"] == 6_000

      # recorded cash equals held, refunded, retained, converted, reduced,
      # and charged-back cash
      assert ledger() == %{
               @zeroed
               | "cash_reduced_cents" => 4_000,
                 "cash_charged_back_cents" => 6_000
             }

      data = json_response(get_payment("op-2"), 200)["data"]
      assert data["reduced_cents"] == 4_000
      assert data["charged_back_cents"] == 6_000

      assert data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
               data["converted_to_credit_cents"] + data["reduced_cents"] +
               data["charged_back_cents"] == data["recorded_cents"]
    end

    test "revokes the credit entitlement a conversion created" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      ])

      conn = post_batch([charge_back_operation("op-4", "op-2")])

      assert hd(results(conn))["charged_back_cents"] == 10_000

      # the lot's entire entitlement is revoked
      assert json_response(get_guest_credit("guest-22"), 200)["data"]["lots"] == []

      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 10_000}
    end

    test "entitlements telescope across several payments in one lot" do
      post_batch([
        open_group_operation("op-1", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_050}]
        }),
        pay_operation("op-2", "group-81", 5_005),
        pay_operation("op-3", "group-81", 5_005),
        cancel_operation("op-4", "group-81", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      ])

      # one lot worth 11_011 backs both payments
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 11_011

      conn = post_batch([charge_back_operation("op-5", "op-2")])
      assert hd(results(conn))["charged_back_cents"] == 5_005

      # entitlement of op-2: round_half_up(5_005 * 1.1) = 5_506
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 5_505

      conn = post_batch([charge_back_operation("op-6", "op-3")])
      assert hd(results(conn))["charged_back_cents"] == 5_005

      # entitlement of op-3 telescopes to 11_011 - 5_506 = 5_505, not 5_506:
      # the lot is exhausted exactly, with no shortfall left behind
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 0

      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 10_010}
    end

    test "an entitlement that cannot be removed becomes a shortfall" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        # 6_000 of the 11_000 lot is spent on another active group
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-13"
        }),
        apply_credit_operation("op-5", "group-82", 6_000, %{"occurred_on" => "2026-11-21"})
      ])

      conn = post_batch([charge_back_operation("op-6", "op-2")])
      assert hd(results(conn))["charged_back_cents"] == 10_000

      # the clawback removes the lot's remaining 5_000 balance first; the
      # entitlement's spent 6_000 becomes unrecovered clawback
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 0

      # the liability still counts credit applied to the active group,
      # including credit covered by the shortfall
      assert ledger() == %{
               @zeroed
               | "cash_charged_back_cents" => 10_000,
                 "credit_liability_cents" => 6_000,
                 "credit_shortfall_cents" => 6_000
             }

      # the chargeback does not change the group funded by the credit
      data = json_response(get_group("group-82"), 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2
    end

    test "non-refundable settlement of credit reduces the shortfall" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{"group_id" => "group-82"}),
        apply_credit_operation("op-5", "group-82", 6_000, %{"occurred_on" => "2026-11-21"}),
        charge_back_operation("op-6", "op-2"),
        # the credit is no longer applied to an active group
        cancel_operation("op-7", "group-82", %{"occurred_on" => "2026-12-01"})
      ])

      assert ledger()["credit_shortfall_cents"] == 0
      assert ledger()["credit_liability_cents"] == 0
    end

    test "credit returning to a shortfalled lot is absorbed first" do
      post_batch([
        # one lot worth 11_011 backs two payments of 5_005
        open_group_operation("op-1", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_050}]
        }),
        pay_operation("op-2", "group-81", 5_005),
        pay_operation("op-3", "group-81", 5_005),
        cancel_operation("op-4", "group-81", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        # a group that stays refundable until 2026-12-27
        open_group_operation("op-5", %{
          "group_id" => "group-82",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-13"
        }),
        apply_credit_operation("op-6", "group-82", 6_000, %{"occurred_on" => "2026-11-21"}),
        # op-2's entitlement of 5_506 removes the lot's remaining 5_011 and
        # leaves 495 of unrecovered clawback
        charge_back_operation("op-7", "op-2")
      ])

      assert ledger()["credit_shortfall_cents"] == 495

      # refundable cancellation restores the 6_000 to the shortfalled lot
      post_batch([cancel_operation("op-8", "group-82", %{"occurred_on" => "2026-11-22"})])

      # the restoration extinguishes the 495 clawback first; only the excess
      # of 5_505 becomes available again, with no second bonus
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 5_505

      assert ledger() == %{
               @zeroed
               | "cash_charged_back_cents" => 5_005,
                 "cash_converted_to_credit_cents" => 5_005,
                 "credit_liability_cents" => 5_505
             }
    end

    test "rejects targets that are not chargeable" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        pay_operation("op-rejected", "group-81", 99_999),
        # fully reduced payment
        open_group_operation("op-3", %{
          "group_id" => "group-82",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_050}]
        }),
        pay_operation("op-4", "group-82", 10_010),
        reduce_cash_operation("op-5", "op-4", 10_010)
      ])

      cases = [
        {"unknown operation", "op-none", "operation_not_found"},
        {"non-payment operation", "op-1", "payment_not_chargeable"},
        {"rejected payment", "op-rejected", "payment_not_chargeable"},
        {"fully reduced payment", "op-4", "payment_not_chargeable"},
        {"already charged back", "op-2", "payment_not_chargeable"}
      ]

      # first charge back op-2 so it can be charged back a second time
      post_batch([charge_back_operation("op-6", "op-2")])

      for {{label, target, code}, n} <- Enum.with_index(cases) do
        conn = post_batch([charge_back_operation("op-#{n + 10}", target)])
        result = hd(results(conn))
        assert result["code"] == code, label
        assert result["status"] == "rejected", label
      end

      # the rejections did not move any cash
      assert ledger() == %{
               @zeroed
               | "cash_charged_back_cents" => 10_000,
                 "cash_reduced_cents" => 10_010
             }
    end

    test "follows the revision contract against the payment's group" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 10_000)])

      conn =
        post_batch([
          charge_back_operation("op-3", "op-2", %{"expected_revision" => 1})
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn =
        post_batch([
          charge_back_operation("op-4", "op-2", %{"expected_revision" => 2})
        ])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["revision"] == 3
    end

    test "is durably idempotent" do
      post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 10_000)])

      operation = charge_back_operation("op-3", "op-2")
      original = hd(results(post_batch([operation])))
      assert results(post_batch([operation])) == [original]

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["revision"] == 3
      assert ledger()["cash_charged_back_cents"] == 10_000
    end
  end

  describe "a combined settlement flow" do
    test "keeps every payment, room, group, and ledger view consistent" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 6_000),
        pay_operation("op-3", "group-81", 6_000),
        reduce_cash_operation("op-4", "op-3", 1_000),
        # room-a's combined 9_000 from both payments becomes one lot
        cancel_rooms_operation("op-5", "group-81", ["room-a"], %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        }),
        charge_back_operation("op-6", "op-2"),
        charge_back_operation("op-7", "op-3"),
        # settles room-b's remaining held cash, which the chargebacks above
        # have already reversed
        cancel_operation("op-8", "group-81", %{"occurred_on" => "2026-11-21"})
      ])

      # the lot was worth 9_900; op-2's entitlement of 6_600 and op-3's
      # telescoped entitlement of 3_300 revoke it exactly
      assert json_response(get_guest_credit("guest-22"), 200)["data"]["lots"] == []

      # recorded cash equals held, refunded, retained, converted, reduced,
      # and charged-back cash: 12_000 == 11_000 + 1_000
      assert ledger() == %{
               @zeroed
               | "cash_reduced_cents" => 1_000,
                 "cash_charged_back_cents" => 11_000
             }

      assert json_response(get_payment("op-2"), 200)["data"] == %{
               "payment_operation_id" => "op-2",
               "original_group_id" => "group-81",
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 6_000
             }

      assert json_response(get_payment("op-3"), 200)["data"] == %{
               "payment_operation_id" => "op-3",
               "original_group_id" => "group-81",
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 5_000
             }

      data = json_response(get_group("group-81"), 200)["data"]
      assert data["status"] == "cancelled"
      assert data["deposit_paid_cents"] == 0

      assert Enum.map(data["rooms"], &{&1["room_id"], &1["status"]}) ==
               [{"room-a", "cancelled"}, {"room-b", "cancelled"}]
    end
  end
end
