defmodule GroupStayWeb.PaymentOperationsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  alias GroupStay.{Group, Payment, Repo}

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the outstanding deposit", %{
      conn: conn
    } do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, reduce_cash(%{"amount_cents" => 500}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-reduce",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 10_000,
                   "revision" => 3
                 }
               ]
             }

      # The reduction came off room-b, the room filled last.
      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      rooms_by_id = Map.new(data["rooms"], &{&1["room_id"], &1})
      assert rooms_by_id["room-a"]["cash_paid_cents"] == 9_000
      assert rooms_by_id["room-b"]["cash_paid_cents"] == 500

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 9_500
      assert ledger["cash_reduced_cents"] == 500
    end

    test "successive reductions compose and an exact remainder is valid", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      json_post(conn, reduce_cash(%{"operation_id" => "reduce-1", "amount_cents" => 500}))

      conn =
        json_post(conn, reduce_cash(%{"operation_id" => "reduce-2", "amount_cents" => 9_500}))

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["amount_cents"] == 9_500
      assert result["outstanding_deposit_cents"] == 19_500

      # Nothing is held anymore.
      conn = json_post(conn, reduce_cash(%{"operation_id" => "reduce-3", "amount_cents" => 1}))
      assert [%{"code" => "payment_not_reducible"}] = json_response(conn, 200)["results"]

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_reduced_cents"] == 10_000
      assert ledger["cash_held_cents"] == 0
    end

    test "a reduction over the held remaining amount is rejected", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, reduce_cash(%{"amount_cents" => 10_001}))

      assert [%{"code" => "reduction_exceeds_held_cash"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 2, "outstanding_deposit_cents" => 9_500} = data
    end

    test "unusable targets and amounts use the prescribed codes", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 1_000}))
      # The reference payment now exists: held cash is 1_000.

      # Unknown operation identifier.
      conn = json_post(conn, reduce_cash(%{"payment_operation_id" => "no-such-pay"}))
      assert [%{"code" => "operation_not_found"}] = json_response(conn, 200)["results"]

      # Legacy funding has no durable operation identity.
      group = Repo.get_by!(Group, group_id: "group-81")

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "payment",
        operation_id: nil,
        amount_cents: 1_000
      })

      conn =
        json_post(
          conn,
          reduce_cash(%{
            "operation_id" => "op-legacy-reduce",
            "payment_operation_id" => "legacy-pay-id"
          })
        )

      assert [%{"code" => "operation_not_found"}] = json_response(conn, 200)["results"]

      # A rejected payment durable record.
      json_post(conn, payment(%{"operation_id" => "pay-over", "amount_cents" => 99_999}))

      conn =
        json_post(
          conn,
          reduce_cash(%{
            "operation_id" => "op-reduce-rejected",
            "payment_operation_id" => "pay-over"
          })
        )

      assert [%{"code" => "payment_not_reducible"}] = json_response(conn, 200)["results"]

      # A non-payment operation record.
      conn =
        json_post(
          conn,
          reduce_cash(%{"operation_id" => "op-reduce-open", "payment_operation_id" => "op-open"})
        )

      assert [%{"code" => "payment_not_reducible"}] = json_response(conn, 200)["results"]

      # Applied payment with no remaining held cash: cancel settles it first.
      json_post(conn, payment(%{"operation_id" => "pay-settle", "amount_cents" => 5_000}))
      json_post(conn, cancel(%{"operation_id" => "op-cancel-settle"}))

      conn =
        json_post(
          conn,
          reduce_cash(%{
            "operation_id" => "op-reduce-settled",
            "payment_operation_id" => "pay-settle"
          })
        )

      assert [%{"code" => "payment_not_reducible"}] = json_response(conn, 200)["results"]

      # Unusable amounts.
      for amount <- [0, -5, 10.5, "100"] do
        op =
          reduce_cash(%{
            "operation_id" => "reduce-bad-#{inspect(amount)}",
            "amount_cents" => amount
          })

        [result] = json_response(json_post(conn, op), 200)["results"]
        assert result["code"] == "invalid_amount"
      end

      op = Map.delete(reduce_cash(%{"operation_id" => "reduce-no-amount"}), "amount_cents")
      [result] = json_response(json_post(conn, op), 200)["results"]
      assert result["code"] == "invalid_operation"
    end

    test "follows the revision contract", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn =
        json_post(
          conn,
          reduce_cash(%{"amount_cents" => 500, "expected_revision" => 1})
        )

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "is durably idempotent and never rewrites the payment's stored result", %{conn: conn} do
      open_group!(conn)
      pay = payment(%{"amount_cents" => 10_000})
      [pay_result] = json_response(json_post(conn, pay), 200)["results"]
      assert pay_result["outstanding_deposit_cents"] == 9_500

      reduce = reduce_cash(%{"amount_cents" => 500})
      [reduce_result] = json_response(json_post(conn, reduce), 200)["results"]
      assert reduce_result["revision"] == 3

      assert [^reduce_result] = json_response(json_post(conn, reduce), 200)["results"]

      assert [%{"code" => "operation_id_conflict"}] =
               json_response(json_post(conn, %{reduce | "amount_cents" => 600}), 200)["results"]

      # Retrying the original payment replays without reapplying cash.
      assert [^pay_result] = json_response(json_post(conn, pay), 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 3
      assert data["outstanding_deposit_cents"] == 10_000
    end
  end

  describe "charge_back_payment" do
    test "reverses all remaining cash from an active payment", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, charge_back())

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-charge-back",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "charged_back_cents" => 10_000,
                   "outstanding_deposit_cents" => 19_500,
                   "revision" => 3
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 19_500

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10_000
    end

    test "a reduced payment charges back only the unreduced remainder", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, reduce_cash(%{"operation_id" => "op-lower", "amount_cents" => 2_000}))

      conn = json_post(conn, charge_back())

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 8_000
      assert result["outstanding_deposit_cents"] == 19_500

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_reduced_cents"] == 2_000
      assert ledger["cash_charged_back_cents"] == 8_000
    end

    test "works for a cancelled group and reclassifies settled dispositions", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, cancel())

      conn = json_post(conn, charge_back())

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_000
      assert result["outstanding_deposit_cents"] == 0
      assert result["revision"] == 4

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10_000
    end

    test "revokes the credit entitlement and reports the resulting shortfall", %{conn: conn} do
      conn = open_and_convert(conn)

      # The target group spends part of the converted credit.
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-target",
            "group_id" => "group-target",
            "guest_id" => "guest-cb"
          })
        ])

      [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-7000",
          "group_id" => "group-target",
          "occurred_on" => "2026-11-15",
          "amount_cents" => 7_000
        })
      )

      conn =
        json_post(
          conn,
          charge_back(%{"payment_operation_id" => "pay-2", "operation_id" => "cb-2"})
        )

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 6_000

      # pay-2's entitlement is 11_000 - 4_400 = 6_600. The lot has 4_000
      # remaining, so 4_000 is clawed back and 2_600 is unrecovered. The
      # shortfall is bounded by the 7_000 still applied to the active group.
      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_shortfall_cents"] == 2_600
      assert ledger["credit_liability_cents"] == 7_000
      assert ledger["cash_charged_back_cents"] == 6_000

      # Credit within the lot is fungible: the target group's view is
      # unchanged, and its revision was not touched by the chargeback.
      data = json_response(get(conn, groups_path("group-target")), 200)["data"]
      assert data["credit_paid_cents"] == 7_000
      assert data["revision"] == 2

      # Nothing is available for new spending.
      credit = json_response(get(conn, guest_credit_path("guest-cb")), 200)["data"]
      assert credit["available_cents"] == 0
    end

    test "a restoration extinguishes the clawback before becoming available", %{conn: conn} do
      conn = open_and_convert(conn)

      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-target",
            "group_id" => "group-target",
            "guest_id" => "guest-cb",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "booked_on" => "2026-10-03"
          })
        ])

      [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-7000",
          "group_id" => "group-target",
          "occurred_on" => "2026-11-15",
          "amount_cents" => 7_000
        })
      )

      json_post(conn, charge_back(%{"payment_operation_id" => "pay-2", "operation_id" => "cb-2"}))

      # Refundable cancellation restores the 7_000: 2_600 extinguishes the
      # unrecovered clawback and 4_400 becomes available again.
      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-target",
            "group_id" => "group-target",
            "occurred_on" => "2027-02-01"
          })
        )

      assert [%{"status" => "applied", "credit_issued_cents" => 0}] =
               json_response(conn, 200)["results"]

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 4_400

      credit = json_response(get(conn, guest_credit_path("guest-cb")), 200)["data"]
      assert credit["available_cents"] == 4_400
    end

    test "entitlements telescope across payments with the senior block first", %{conn: conn} do
      open_group!(conn)
      group = Repo.get_by!(Group, group_id: "group-81")

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "payment",
        operation_id: nil,
        amount_cents: 4_000
      })

      json_post(conn, payment(%{"operation_id" => "pay-1", "amount_cents" => 6_000}))

      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-all",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert [%{"status" => "applied", "credit_issued_cents" => 11_000}] =
               json_response(conn, 200)["results"]

      # The durable payment's entitlement is bonus(10_000) - bonus(4_000)
      # = 11_000 - 4_400 = 6_600; the senior block keeps its 4_400.
      conn =
        json_post(
          conn,
          charge_back(%{"payment_operation_id" => "pay-1", "operation_id" => "cb-1"})
        )

      assert [%{"status" => "applied", "charged_back_cents" => 6_000}] =
               json_response(conn, 200)["results"]

      credit = json_response(get(conn, guest_credit_path("guest-22")), 200)["data"]
      assert credit["available_cents"] == 4_400

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "chargebacks are once-only and rejected for unusable targets", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, charge_back())

      conn = json_post(conn, charge_back(%{"operation_id" => "cb-again"}))
      assert [%{"code" => "payment_not_chargeable"}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          charge_back(%{"operation_id" => "cb-none", "payment_operation_id" => "no-such-pay"})
        )

      assert [%{"code" => "operation_not_found"}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          charge_back(%{"payment_operation_id" => "op-open", "operation_id" => "cb-open"})
        )

      assert [%{"code" => "payment_not_chargeable"}] = json_response(conn, 200)["results"]

      json_post(conn, payment(%{"operation_id" => "pay-over", "amount_cents" => 99_999}))

      conn =
        json_post(
          conn,
          charge_back(%{"payment_operation_id" => "pay-over", "operation_id" => "cb-rejected"})
        )

      assert [%{"code" => "payment_not_chargeable"}] = json_response(conn, 200)["results"]
    end

    test "a fully reduced payment cannot be charged back", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, reduce_cash(%{"operation_id" => "op-whole", "amount_cents" => 10_000}))

      conn = json_post(conn, charge_back())
      assert [%{"code" => "payment_not_chargeable"}] = json_response(conn, 200)["results"]
    end

    test "follows the revision contract and is durably idempotent", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, charge_back(%{"expected_revision" => 1}))

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      op = charge_back(%{"operation_id" => "cb-ok"})
      [original] = json_response(json_post(conn, op), 200)["results"]
      assert original["revision"] == 3

      assert [^original] = json_response(json_post(conn, op), 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 3
    end
  end

  describe "payment reconciliation" do
    test "returns the current disposition of a recorded payment", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, reduce_cash(%{"operation_id" => "op-lower", "amount_cents" => 500}))

      json_post(
        conn,
        cancel_rooms(%{"operation_id" => "op-cancel-b", "room_ids" => ["room-b"]})
      )

      json_post(
        conn,
        cancel_rooms(%{
          "operation_id" => "op-cancel-a",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        })
      )

      assert json_response(get(conn, payments_path("op-pay")), 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10_000,
                 "held_cents" => 0,
                 "refunded_cents" => 500,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 9_000,
                 "reduced_cents" => 500,
                 "charged_back_cents" => 0
               }
             }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_refunded_cents"] == 500
      assert ledger["cash_converted_to_credit_cents"] == 9_000
      assert ledger["cash_reduced_cents"] == 500
    end

    test "every disposition field is present, including zeros", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      statement = json_response(get(conn, payments_path("op-pay")), 200)["data"]

      assert statement == %{
               "payment_operation_id" => "op-pay",
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

    test "after a chargeback the dispositions sum to the recorded amount", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, reduce_cash(%{"operation_id" => "op-lower", "amount_cents" => 1_000}))
      json_post(conn, charge_back())

      statement = json_response(get(conn, payments_path("op-pay")), 200)["data"]

      disposition =
        statement["held_cents"] + statement["refunded_cents"] + statement["retained_cents"] +
          statement["converted_to_credit_cents"] + statement["reduced_cents"] +
          statement["charged_back_cents"]

      assert disposition == statement["recorded_cents"]
      assert statement["reduced_cents"] == 1_000
      assert statement["charged_back_cents"] == 9_000
      assert statement["held_cents"] == 0
    end

    test "unknown payments are 404 and non-payments are 422", %{conn: conn} do
      assert json_response(get(conn, payments_path("no-such-pay")), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      open_group!(conn)

      assert json_response(get(conn, payments_path("op-open")), 422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      json_post(conn, payment(%{"operation_id" => "pay-over", "amount_cents" => 99_999}))
      assert json_response(get(conn, payments_path("pay-over")), 422)
    end
  end

  # Opens a group for guest-cb funded by two durable payments, then converts
  # the combined cash to hotel credit: one lot of 11_000.
  defp open_and_convert(conn) do
    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-src",
          "group_id" => "group-src",
          "guest_id" => "guest-cb"
        }),
        payment(%{
          "operation_id" => "pay-1",
          "group_id" => "group-src",
          "amount_cents" => 4_000
        }),
        payment(%{
          "operation_id" => "pay-2",
          "group_id" => "group-src",
          "amount_cents" => 6_000
        }),
        cancel(%{
          "operation_id" => "cancel-src",
          "group_id" => "group-src",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      ])

    [_, _, _, %{"status" => "applied", "credit_issued_cents" => 11_000}] =
      json_response(conn, 200)["results"]

    conn
  end
end
