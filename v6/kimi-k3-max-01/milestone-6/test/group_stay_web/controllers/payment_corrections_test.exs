defmodule GroupStayWeb.PaymentCorrectionsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  # Opens and funds the default group with one cash payment of `amount`.
  defp open_and_fund!(conn, amount, overrides \\ %{}) do
    apply_batch!(conn, [
      open_group_op(),
      record_cash_payment_op(Map.merge(%{"amount_cents" => amount}, overrides))
    ])
  end

  describe "reduce_cash_payment" do
    test "reopens the outstanding deposit and reclassifies held cash", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      [result] = post_batch!(fresh_conn(), [reduce_cash_payment_op(%{"amount_cents" => 4_000})])

      assert result == %{
               "operation_id" => "op-7001",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 13_500,
               "revision" => 3
             }

      ledger = get_ledger!(fresh_conn())
      assert ledger["cash_held_cents"] == 6_000
      assert ledger["cash_reduced_cents"] == 4_000

      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["recorded_cents"] == 10_000
      assert statement["held_cents"] == 6_000
      assert statement["reduced_cents"] == 4_000

      # room-a keeps the remaining 6_000 of the payment's fill.
      group = get_group!(fresh_conn(), "group-81")
      assert hd(group["rooms"])["cash_paid_cents"] == 6_000
    end

    test "removes held allocations of the payment in reverse fill order", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000}),
        record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 10_500})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{"payment_operation_id" => "op-2001", "amount_cents" => 4_000})
        ])

      assert result["status"] == "applied"

      group = get_group!(fresh_conn(), "group-81")
      [room_a, room_b] = group["rooms"]

      # op-2001 filled room-a; the reduction takes room-a down to 5_000
      # while op-2002's funding of room-b is untouched.
      assert room_a["cash_paid_cents"] == 5_000
      assert room_b["cash_paid_cents"] == 10_500
      assert group["outstanding_deposit_cents"] == 4_000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      results =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{"amount_cents" => 4_000}),
          reduce_cash_payment_op(%{
            "operation_id" => "op-7002",
            "payment_operation_id" => "op-2001",
            "amount_cents" => 6_000
          })
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
      assert Enum.at(results, 1)["outstanding_deposit_cents"] == 19_500

      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 10_000

      # Nothing is left to reduce.
      [rejected] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{"operation_id" => "op-7003", "amount_cents" => 1})
        ])

      assert rejected["code"] == "payment_not_reducible"
    end

    test "an amount equal to the complete remaining held portion is valid", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      [result] =
        post_batch!(fresh_conn(), [reduce_cash_payment_op(%{"amount_cents" => 10_000})])

      assert result["status"] == "applied"
      assert get_group!(fresh_conn(), "group-81")["outstanding_deposit_cents"] == 19_500
    end

    test "rejects corrections for unknown payment identifiers", %{conn: conn} do
      [result] =
        post_batch!(conn, [reduce_cash_payment_op(%{"payment_operation_id" => "op-no-such"})])

      assert result["code"] == "operation_not_found"
    end

    test "rejects targets that can never accept a reduction", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 5_000}),
        cancel_group_op()
      ])

      for {target, code, index} <-
            [
              # A non-payment operation.
              {"op-1001", "payment_not_reducible"},
              # Another non-payment operation.
              {"op-4001", "payment_not_reducible"},
              # An applied payment with no held cash remaining (fully
              # settled by the cancellation above).
              {"op-2001", "payment_not_reducible"}
            ]
            |> Enum.with_index() do
        [result] =
          post_batch!(fresh_conn(), [
            reduce_cash_payment_op(%{
              "operation_id" => "op-700#{index}",
              "payment_operation_id" => target
            })
          ])

        assert result["code"] == code, "target=#{target}"
      end
    end

    test "a rejected payment target reports its own rejection code", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      # A payment rejected for exceeding the outstanding deposit.
      [rejected_payment] =
        post_batch!(fresh_conn(), [
          record_cash_payment_op(%{
            "operation_id" => "op-forbidden",
            "amount_cents" => 20_000
          })
        ])

      assert rejected_payment["code"] == "payment_exceeds_outstanding"

      [result] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{
            "operation_id" => "op-2003",
            "payment_operation_id" => "op-forbidden"
          })
        ])

      assert result["code"] == "payment_not_reducible"
    end

    test "rejects non-positive amounts and excess amounts", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      for {amount, index} <- Enum.with_index([0, -1, "100", 1.5]) do
        [result] =
          post_batch!(fresh_conn(), [
            reduce_cash_payment_op(%{
              "operation_id" => "op-amt-#{index}",
              "amount_cents" => amount
            })
          ])

        assert result["code"] == "invalid_amount", "amount=#{inspect(amount)}"
      end

      [result] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{"operation_id" => "op-too-much", "amount_cents" => 10_001})
        ])

      assert result["code"] == "reduction_exceeds_held_cash"
      assert get_group!(fresh_conn(), "group-81")["outstanding_deposit_cents"] == 9_500
    end

    test "checks expected_revision against the original payment group", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      [result] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{"amount_cents" => 4_000, "expected_revision" => 2})
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 3

      [stale] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{
            "operation_id" => "op-7002",
            "amount_cents" => 4_000,
            "expected_revision" => 2
          })
        ])

      assert stale == %{
               "operation_id" => "op-7002",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }
    end

    test "is durably idempotent", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      op = reduce_cash_payment_op(%{"amount_cents" => 4_000})
      [original] = post_batch!(fresh_conn(), [op])

      [replay] = post_batch!(fresh_conn(), [op])
      assert replay == original

      assert get_group!(fresh_conn(), "group-81")["deposit_paid_cents"] == 6_000
      assert get_operation!(fresh_conn(), "op-7001") == original
    end
  end

  describe "charge_back_payment" do
    test "reverses the whole remaining held payment and reopens the deposit", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      [result] = post_batch!(fresh_conn(), [charge_back_payment_op()])

      assert result == %{
               "operation_id" => "op-8001",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      ledger = get_ledger!(fresh_conn())
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10_000
      assert ledger["cash_reduced_cents"] == 0

      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["held_cents"] == 0
      assert statement["charged_back_cents"] == 10_000

      # A second chargeback has nothing left to reverse.
      [again] =
        post_batch!(fresh_conn(), [charge_back_payment_op(%{"operation_id" => "op-8002"})])

      assert again["code"] == "payment_not_chargeable"
    end

    test "reverses a reduced payment except the reduced portion", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      apply_batch!(fresh_conn(), [reduce_cash_payment_op(%{"amount_cents" => 4_000})])

      [result] = post_batch!(fresh_conn(), [charge_back_payment_op()])

      assert result["charged_back_cents"] == 6_000

      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["reduced_cents"] == 4_000
      assert statement["charged_back_cents"] == 6_000
      assert statement["held_cents"] == 0
    end

    test "reclassifies a settled refund without reversing the historical refund", %{
      conn: conn
    } do
      open_and_fund!(conn, 10_000)

      apply_batch!(fresh_conn(), [cancel_group_op()])

      [result] = post_batch!(fresh_conn(), [charge_back_payment_op()])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_000
      assert result["outstanding_deposit_cents"] == 0

      ledger = get_ledger!(fresh_conn())
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10_000

      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["refunded_cents"] == 0
      assert statement["charged_back_cents"] == 10_000
    end

    test "a cancelled group can have its payment charged back", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      apply_batch!(fresh_conn(), [cancel_group_op()])

      [result] = post_batch!(fresh_conn(), [charge_back_payment_op()])
      assert result["status"] == "applied"
    end

    test "rejects chargebacks on non-payment, reduced-away, and charged-back records", %{
      conn: conn
    } do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      # Non-payment record.
      [non_payment] =
        post_batch!(fresh_conn(), [
          charge_back_payment_op(%{"payment_operation_id" => "op-1001"})
        ])

      assert non_payment["code"] == "payment_not_chargeable"

      # Fully reduced payment.
      apply_batch!(fresh_conn(), [
        reduce_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      [reduced_away] =
        post_batch!(fresh_conn(), [
          charge_back_payment_op(%{"operation_id" => "op-8002"})
        ])

      assert reduced_away["code"] == "payment_not_chargeable"
    end

    test "checks expected_revision against the original payment group", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      [result] =
        post_batch!(fresh_conn(), [
          charge_back_payment_op(%{"expected_revision" => 2})
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end

    test "is durably idempotent", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      op = charge_back_payment_op()
      [original] = post_batch!(fresh_conn(), [op])
      [replay] = post_batch!(fresh_conn(), [op])

      assert replay == original
      assert get_group!(fresh_conn(), "group-81")["deposit_paid_cents"] == 0
    end
  end

  describe "credit entitlements and shortfalls" do
    # Payments of 9_000 (op-2001) and 10_500 (op-2002) settle into a lot of
    # 21_450.
    defp settle_with_two_payments!(conn) do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000}),
        record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 10_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"})
      ])
    end

    # Entitlements are the standard 10%-bonus value (cash plus bonus) of
    # settled cash through each payment minus the bonus value through the
    # preceding payment: 9_900 for op-2001 and 11_550 for op-2002, together
    # the issued 21_450.

    test "entitlements telescope exactly to the issued lot", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000}),
        record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 10_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"})
      ])

      assert get_credit!(fresh_conn(), "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "op-4001",
                 "remaining_cents" => 21_450,
                 "expires_on" => "2027-11-02"
               }
             ]

      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 21_450
    end

    test "a chargeback removes the payment's entitlement from the lot's remaining balance", %{
      conn: conn
    } do
      settle_with_two_payments!(conn)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000})
      ])

      # The lot holds 21_450; 9_000 is applied and 12_450 remains. op-2001's
      # entitlement of 9_900 is fully recovered from the remaining balance,
      # so the liability drops to 11_550 with no shortfall.
      [result] = post_batch!(fresh_conn(), [charge_back_payment_op()])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 9_000

      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 21_450 - 9_900
      assert get_ledger!(fresh_conn())["credit_shortfall_cents"] == 0
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 2_550
    end

    test "any entitlement that cannot be removed becomes an unrecovered clawback", %{
      conn: conn
    } do
      settle_with_two_payments!(conn)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        open_group_op(%{"operation_id" => "op-83", "group_id" => "group-83"}),
        apply_hotel_credit_op(%{
          "operation_id" => "op-5002",
          "group_id" => "group-83",
          "amount_cents" => 10_500
        })
      ])

      # The lot holds 21_450; 19_500 is applied and 1_950 remains. op-2002's
      # entitlement of 11_550 exceeds the remaining balance by 9_600, which
      # becomes the lot's unrecovered clawback and current shortfall.
      [result] =
        post_batch!(fresh_conn(), [
          charge_back_payment_op(%{
            "operation_id" => "op-8001",
            "payment_operation_id" => "op-2002"
          })
        ])

      assert result["status"] == "applied"

      ledger = get_ledger!(fresh_conn())
      assert ledger["credit_shortfall_cents"] == 9_600
      assert ledger["credit_liability_cents"] == 19_500

      # Credit returning to the shortfalled lot extinguishes the clawback
      # before any amount becomes available again.
      apply_batch!(fresh_conn(), [
        cancel_group_op(%{
          "operation_id" => "op-cancel-83",
          "group_id" => "group-83",
          "occurred_on" => "2026-11-20"
        })
      ])

      assert get_ledger!(fresh_conn())["credit_shortfall_cents"] == 0
      # 10_500 returned: 9_600 absorbed, 900 newly available; the 9_000
      # applied to group-82 is untouched.
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 900
      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 900 + 9_000
    end

    test "non-refundable settlement reduces the shortfall automatically", %{conn: conn} do
      settle_with_two_payments!(conn)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          charge_back_payment_op(%{"payment_operation_id" => "op-2002"})
        ])

      assert result["status"] == "applied"

      # op-2002's entitlement of 11_550 fits the remaining 12_450, so no
      # shortfall remains.
      assert get_ledger!(fresh_conn())["credit_shortfall_cents"] == 0

      # The applied 9_000 is consumed by a non-refundable cancellation,
      # shrinking the liability to the remaining 900.
      apply_batch!(fresh_conn(), [
        cancel_group_op(%{
          "operation_id" => "op-cancel-82",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-09"
        })
      ])

      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 900
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns exactly the statement fields, including zeros", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      assert get_payment!(fresh_conn(), "op-2001") == %{
               "payment_operation_id" => "op-2001",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 10_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "agrees with the group and ledger views", %{conn: conn} do
      open_and_fund!(conn, 10_000)

      apply_batch!(fresh_conn(), [cancel_group_op(%{"refund_method" => "hotel_credit"})])

      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["held_cents"] == 0
      assert statement["converted_to_credit_cents"] == 10_000

      disposition_sum =
        for field <-
              [
                "held_cents",
                "refunded_cents",
                "retained_cents",
                "converted_to_credit_cents",
                "reduced_cents",
                "charged_back_cents"
              ],
            do: statement[field]

      assert Enum.sum(disposition_sum) == statement["recorded_cents"]

      # Reading a statement never changes state.
      assert get_payment!(fresh_conn(), "op-2001") == statement
    end

    test "returns 404 for an unknown identifier", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/payments/op-never-seen")
        |> json_response(404)

      assert response == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 for a record that is not an applied cash payment", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), cancel_group_op()])

      for target <- ["op-1001", "op-4001"] do
        response =
          fresh_conn()
          |> get(~p"/api/v1/payments/#{target}")
          |> json_response(422)

        assert response == %{"error" => %{"code" => "payment_not_reconcilable"}},
               "target=#{target}"
      end
    end
  end
end
