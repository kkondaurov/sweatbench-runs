defmodule GroupStayWeb.PaymentOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp get_group(group_id) do
    {body, 200} = api_get(build_conn(), "/api/v1/groups/#{group_id}")
    body["data"]
  end

  defp get_ledger(query \\ "") do
    api_get(build_conn(), "/api/v1/ledger#{query}")
  end

  defp get_payment(payment_operation_id) do
    api_get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns every disposition field for an applied cash payment" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} = get_payment("op-2001")

      assert body == %{
               "data" => %{
                 "payment_operation_id" => "op-2001",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5_000,
                 "held_cents" => 5_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end

    test "agrees with group, room, and ledger views after settlement" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])
      {_, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      {body, 200} = get_payment("op-2001")

      assert body["data"] == %{
               "payment_operation_id" => "op-2001",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 10_000
      assert ledger["data"]["cash_held_cents"] == 0
    end

    test "reading a statement never changes state" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      group_before = get_group("group-81")
      {ledger_before, 200} = get_ledger()

      {_, 200} = get_payment("op-2001")
      {_, 200} = get_payment("op-2001")

      assert get_group("group-81") == group_before
      assert elem(get_ledger(), 1) == 200
      assert elem(get_ledger(), 0) == ledger_before
    end

    test "returns operation_not_found when no durable record exists" do
      {body, 404} = get_payment("op-never")
      assert body == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns payment_not_reconcilable for non-payments and rejections" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 99_999})])

      {body, 422} = get_payment("op-1001")
      assert body == %{"error" => %{"code" => "payment_not_reconcilable"}}

      {body, 422} = get_payment("op-2001")
      assert body == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end

  describe "reduce_cash_payment" do
    setup do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      :ok
    end

    test "reduces held cash and reopens the outstanding deposit" do
      {body, 200} = post_ops([reduce_cash_payment_op(%{"amount_cents" => 2_000})])

      assert result(body) == %{
               "operation_id" => "op-7001",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 3
             }

      group = get_group("group-81")
      assert group["cash_paid_cents"] == 3_000
      assert group["outstanding_deposit_cents"] == 16_500
      assert group["revision"] == 3

      {body, 200} = get_payment("op-2001")

      assert body["data"] == %{
               "payment_operation_id" => "op-2001",
               "original_group_id" => "group-81",
               "recorded_cents" => 5_000,
               "held_cents" => 3_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2_000,
               "charged_back_cents" => 0
             }

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_reduced_cents"] == 2_000
      assert ledger["data"]["cash_held_cents"] == 3_000
    end

    test "successive reductions compose and a full reduction is valid" do
      {_, 200} = post_ops([reduce_cash_payment_op(%{"amount_cents" => 2_000})])

      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{"operation_id" => "op-7002", "amount_cents" => 3_000})
        ])

      assert result(body) == %{
               "operation_id" => "op-7002",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "amount_cents" => 3_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["reduced_cents"] == 5_000

      # Everything held is already reduced, so nothing can be reduced
      # further.
      {body, 200} = post_ops([reduce_cash_payment_op(%{"operation_id" => "op-7003"})])
      assert result(body)["code"] == "payment_not_reducible"
    end

    test "removes held allocations in reverse fill order" do
      open =
        open_group_op(%{
          "operation_id" => "op-rf-open",
          "group_id" => "group-rf",
          "occurred_on" => "2026-10-03"
        })

      {_, 200} = post_ops([open])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-rf-pay",
            "group_id" => "group-rf",
            "amount_cents" => 10_000
          })
        ])

      # The payment funded room-a completely (9,000) and then room-b with
      # 1,000 cents. A 2,500-cent reduction drains room-b first, leaving
      # room-a with 7,000 of the payment.
      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{
            "group_id" => "group-rf",
            "payment_operation_id" => "op-rf-pay",
            "amount_cents" => 2_500
          })
        ])

      assert result(body)["status"] == "applied"

      group = get_group("group-rf")
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [7_500, 0]

      {body, 200} = get_payment("op-rf-pay")
      assert body["data"]["held_cents"] == 7_500
      assert body["data"]["reduced_cents"] == 2_500
    end

    test "settled cash is history and never moves through a reduction" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 4_500})
        ])

      {_, 200} =
        post_ops([
          cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-26"})
        ])

      # op-2001's 5,000 cents funded room-a and were refunded at settlement;
      # there is nothing held left to reduce.
      {body, 200} =
        post_ops([reduce_cash_payment_op(%{"amount_cents" => 5_000})])

      assert result(body)["code"] == "payment_not_reducible"

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["refunded_cents"] == 5_000

      # op-2002 still holds 500 cents on room-b: a bigger reduction exceeds
      # the held cash.
      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{
            "operation_id" => "op-7011",
            "payment_operation_id" => "op-2002",
            "amount_cents" => 1_000
          })
        ])

      assert result(body)["code"] == "reduction_exceeds_held_cash"
    end

    test "rejects unusable targets and amounts" do
      {body, 200} =
        post_ops([reduce_cash_payment_op(%{"payment_operation_id" => "op-never"})])

      assert result(body) == %{
               "operation_id" => "op-7001",
               "status" => "rejected",
               "code" => "operation_not_found"
             }

      # A non-payment operation can never be reduced.
      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{
            "operation_id" => "op-7020",
            "payment_operation_id" => "op-1001"
          })
        ])

      assert result(body)["code"] == "payment_not_reducible"

      # A rejected payment can never be reduced.
      {_, 200} =
        post_ops([
          cash_payment_op(%{"operation_id" => "op-2009", "amount_cents" => 99_999})
        ])

      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{
            "operation_id" => "op-7021",
            "payment_operation_id" => "op-2009"
          })
        ])

      assert result(body)["code"] == "payment_not_reducible"

      for {amount, index} <- Enum.with_index([0, -100, 1.5]) do
        {body, 200} =
          post_ops([
            reduce_cash_payment_op(%{
              "operation_id" => "op-720#{index}",
              "amount_cents" => amount
            })
          ])

        assert result(body)["code"] == "invalid_amount",
               "expected invalid_amount for #{inspect(amount)}"
      end

      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{"operation_id" => "op-7250", "amount_cents" => 5_001})
        ])

      assert result(body)["code"] == "reduction_exceeds_held_cash"
    end

    test "checks the addressed group's revision before domain rules" do
      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{"expected_revision" => 9, "amount_cents" => 999_999})
        ])

      assert result(body) == %{
               "operation_id" => "op-7001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }
    end

    test "an equivalent retry returns the exact original result without side effects" do
      {body, 200} =
        post_ops([reduce_cash_payment_op(%{"amount_cents" => 2_000, "expected_revision" => 2})])

      applied = result(body)

      {retry_body, 200} =
        post_ops([
          %{
            "payment_operation_id" => "op-2001",
            "amount_cents" => 2_000,
            "expected_revision" => 2,
            "operation_id" => "op-7001",
            "type" => "reduce_cash_payment"
          }
        ])

      assert result(retry_body) == applied
      assert get_group("group-81")["revision"] == 3
      assert get_group("group-81")["cash_paid_cents"] == 3_000
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash and reopens the outstanding deposit" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])

      {body, 200} =
        post_ops([charge_back_payment_op(%{"payment_operation_id" => "op-2001"})])

      assert result(body) == %{
               "operation_id" => "op-8001",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      group = get_group("group-81")
      assert group["cash_paid_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["charged_back_cents"] == 10_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 10_000
      assert ledger["data"]["cash_refunded_cents"] == 0
    end

    test "charges back cash after a refundable settlement without reversing the refund" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      {_, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      {body, 200} = post_ops([charge_back_payment_op()])

      assert result(body)["charged_back_cents"] == 5_000
      assert result(body)["outstanding_deposit_cents"] == 0

      {body, 200} = get_payment("op-2001")
      assert body["data"]["refunded_cents"] == 0
      assert body["data"]["charged_back_cents"] == 5_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 5_000
    end

    test "charges back cash retained by a non-refundable settlement" do
      {_, 200} = post_ops([open_group_op(%{"rate_plan" => "advance_purchase"})])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      {_, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-10-10"})])

      {body, 200} = post_ops([charge_back_payment_op()])

      assert result(body)["charged_back_cents"] == 5_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_retained_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 5_000
    end

    test "revokes the credit entitlement created by converted cash" do
      {_, 200} =
        post_ops([
          open_group_op(),
          cash_payment_op(%{"amount_cents" => 10_000}),
          cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        ])

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert credit["data"]["available_cents"] == 11_000

      {body, 200} = post_ops([charge_back_payment_op()])
      assert result(body)["charged_back_cents"] == 10_000

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert credit["data"]["available_cents"] == 0
      assert credit["data"]["lots"] == []

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_converted_to_credit_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 10_000
      assert ledger["data"]["credit_liability_cents"] == 0
    end

    test "apportions a conversion lot across payments with telescoping half-up bonuses" do
      {_, 200} =
        post_ops([
          open_group_op(%{
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 20_000}]
          }),
          cash_payment_op(%{
            "operation_id" => "pay-a",
            "occurred_on" => "2026-01-06",
            "amount_cents" => 1_506
          }),
          cash_payment_op(%{
            "operation_id" => "pay-b",
            "occurred_on" => "2026-01-06",
            "amount_cents" => 1_505
          }),
          cash_payment_op(%{
            "operation_id" => "pay-c",
            "occurred_on" => "2026-01-06",
            "amount_cents" => 1_504
          }),
          cancel_op(%{
            "operation_id" => "cancel-x",
            "occurred_on" => "2026-01-20",
            "refund_method" => "hotel_credit"
          })
        ])

      # Running bonus values: 1506 -> 1657; 3011 -> 3312; 4515 -> 4967.
      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert credit["data"]["available_cents"] == 4_967

      {body, 200} = post_ops([charge_back_payment_op(%{"payment_operation_id" => "pay-b"})])

      assert result(body)["charged_back_cents"] == 1_505

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      # 4967 - 1655 = 3312 remains available to the guest.
      assert credit["data"]["available_cents"] == 3_312
    end

    test "a clawback over spent credit becomes a shortfall against applied credit" do
      {_, 200} =
        post_ops([
          open_group_op(%{
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 20_000}]
          }),
          cash_payment_op(%{
            "operation_id" => "pay-a",
            "occurred_on" => "2026-01-06",
            "amount_cents" => 10_000
          }),
          cancel_op(%{
            "operation_id" => "cancel-x",
            "occurred_on" => "2026-01-20",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-open",
            "guest_id" => "guest-22",
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-w", "nightly_rate_cents" => 20_000}]
          }),
          apply_hotel_credit_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-apply",
            "occurred_on" => "2026-01-21",
            "amount_cents" => 10_000
          })
        ])

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 11_000
      assert ledger["data"]["credit_shortfall_cents"] == 0

      {_, 200} = post_ops([charge_back_payment_op(%{"payment_operation_id" => "pay-a"})])

      # The lot still holds 1,000 unapplied; the chargeback removes it and
      # 10,000 remains uncovered against credit applied to the other group.
      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 10_000
      assert ledger["data"]["credit_shortfall_cents"] == 10_000

      # The other group is untouched and its revision does not move.
      assert get_group("group-other")["revision"] == 2
    end

    test "restoration is absorbed by shortfall before credit becomes available again" do
      {_, 200} =
        post_ops([
          open_group_op(%{
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 20_000}]
          }),
          cash_payment_op(%{
            "operation_id" => "pay-a",
            "occurred_on" => "2026-01-06",
            "amount_cents" => 10_000
          }),
          cancel_op(%{
            "operation_id" => "cancel-x",
            "occurred_on" => "2026-01-20",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-open",
            "guest_id" => "guest-22",
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-w", "nightly_rate_cents" => 20_000}]
          }),
          apply_hotel_credit_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-apply",
            "occurred_on" => "2026-01-21",
            "amount_cents" => 10_000
          }),
          charge_back_payment_op(%{"operation_id" => "cb-1", "payment_operation_id" => "pay-a"}),
          cancel_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-cancel",
            "occurred_on" => "2026-01-22"
          })
        ])

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_shortfall_cents"] == 0
      assert ledger["data"]["credit_liability_cents"] == 0

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      # The restored credit extinguishes the clawback before anything can
      # become available: the whole applied amount was absorbed and nothing
      # is left for the guest.
      assert credit["data"]["available_cents"] == 0
    end

    test "non-refundable settlement of applied credit shinks the shortfall" do
      {_, 200} =
        post_ops([
          open_group_op(%{
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 20_000}]
          }),
          cash_payment_op(%{
            "operation_id" => "pay-a",
            "occurred_on" => "2026-01-06",
            "amount_cents" => 10_000
          }),
          cancel_op(%{
            "operation_id" => "cancel-x",
            "occurred_on" => "2026-01-20",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-open",
            "guest_id" => "guest-22",
            "occurred_on" => "2026-01-05",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-w", "nightly_rate_cents" => 20_000}]
          }),
          apply_hotel_credit_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-apply",
            "occurred_on" => "2026-01-21",
            "amount_cents" => 10_000
          }),
          charge_back_payment_op(%{"operation_id" => "cb-1", "payment_operation_id" => "pay-a"}),
          cancel_op(%{
            "group_id" => "group-other",
            "operation_id" => "op-other-cancel",
            "occurred_on" => "2026-08-01"
          })
        ])

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_shortfall_cents"] == 0
      assert ledger["data"]["credit_liability_cents"] == 0
    end

    test "rejects unusable chargeback targets" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} =
        post_ops([
          charge_back_payment_op(%{
            "operation_id" => "op-8300",
            "payment_operation_id" => "op-never"
          })
        ])

      assert result(body)["code"] == "operation_not_found"

      {body, 200} =
        post_ops([
          charge_back_payment_op(%{
            "operation_id" => "op-8301",
            "payment_operation_id" => "op-1001"
          })
        ])

      assert result(body)["code"] == "payment_not_chargeable"

      {_, 200} =
        post_ops([
          cash_payment_op(%{"operation_id" => "op-2009", "amount_cents" => 99_999})
        ])

      {body, 200} =
        post_ops([
          charge_back_payment_op(%{
            "operation_id" => "op-8302",
            "payment_operation_id" => "op-2009"
          })
        ])

      assert result(body)["code"] == "payment_not_chargeable"
    end

    test "a fully reduced payment cannot be charged back" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      {_, 200} = post_ops([reduce_cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} = post_ops([charge_back_payment_op()])
      assert result(body)["code"] == "payment_not_chargeable"
    end

    test "an already charged-back payment cannot be charged back again" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      {_, 200} = post_ops([charge_back_payment_op()])

      {body, 200} =
        post_ops([charge_back_payment_op(%{"operation_id" => "op-8002"})])

      assert result(body)["code"] == "payment_not_chargeable"
      assert get_group("group-81")["revision"] == 3
    end

    test "checks the addressed group's revision before charging back" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} =
        post_ops([charge_back_payment_op(%{"expected_revision" => 9})])

      assert result(body) == %{
               "operation_id" => "op-8001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }
    end

    test "an equivalent retry returns the exact original result without side effects" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} = post_ops([charge_back_payment_op()])
      applied = result(body)

      {retry_body, 200} =
        post_ops([
          %{
            "payment_operation_id" => "op-2001",
            "operation_id" => "op-8001",
            "type" => "charge_back_payment"
          }
        ])

      assert result(retry_body) == applied
      assert get_group("group-81")["revision"] == 3

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_charged_back_cents"] == 5_000
    end
  end
end
