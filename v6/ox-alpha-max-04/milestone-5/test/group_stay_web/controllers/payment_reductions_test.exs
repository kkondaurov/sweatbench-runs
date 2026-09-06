defmodule GroupStayWeb.Controllers.PaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: true

  @occurred_on "2026-10-03"

  describe "reduce_cash_payment" do
    test "removes held allocations in reverse fill order and reopens the outstanding deposit", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000})
        ])

      # The payment filled room-a (9_000) then room-b (1_000). A reduction of
      # 5_000 removes room-b's 1_000 first and then 4_000 of room-a's.
      conn =
        post_operations(conn, [
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 5_000})
        ])

      assert %{"results" => [reduction]} = json_response(conn, 200)

      assert reduction == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 3
             }

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 5_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ],
               "cash_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500
             } = fetch_group!(conn, "group-81")

      assert %{"cash_held_cents" => 5_000, "cash_reduced_cents" => 5_000} = ledger(conn)
    end

    test "successive reductions compose against the payment's remaining held cash", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          reduce_operation(%{"operation_id" => "op-reduce-1", "amount_cents" => 5_000}),
          reduce_operation(%{"operation_id" => "op-reduce-2", "amount_cents" => 4_000})
        ])

      assert %{"results" => [_, _, _, second]} = json_response(conn, 200)
      assert %{"outstanding_deposit_cents" => 18_500, "revision" => 4} = second

      assert %{"cash_reduced_cents" => 9_000, "cash_held_cents" => 1_000} = ledger(conn)
    end

    test "a reduction equal to the complete remaining held portion is valid", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 10_000})
        ])

      assert %{"results" => [_, _, %{"outstanding_deposit_cents" => 19_500}]} =
               json_response(conn, 200)

      assert %{
               "cash_held_cents" => 0,
               "cash_reduced_cents" => 10_000,
               "credit_shortfall_cents" => 0
             } = ledger(conn)

      assert %{"rooms" => [%{"cash_paid_cents" => 0}, %{"cash_paid_cents" => 0}]} =
               fetch_group!(conn, "group-81")
    end

    test "returns operation_not_found for an unknown payment", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          reduce_operation(%{"payment_operation_id" => "no-such-payment"})
        ])

      assert_rejected(conn, "operation_not_found")
    end

    test "returns payment_not_reducible for a target that is not an applied cash payment", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-excess", "amount_cents" => 999_999})
        ])

      assert %{"results" => [_, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "payment_exceeds_outstanding"

      for payment_operation_id <- ["op-1001", "op-excess"] do
        conn =
          post_operations(conn, [
            reduce_operation(%{
              "operation_id" => "op-reduce-#{payment_operation_id}",
              "payment_operation_id" => payment_operation_id,
              "amount_cents" => 1_000
            })
          ])

        assert_rejected(conn, "payment_not_reducible")
      end
    end

    test "returns payment_not_reducible when no held cash remains", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 10_000})
        ])

      assert %{"results" => [_, _, _]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          reduce_operation(%{"operation_id" => "op-again", "amount_cents" => 1_000})
        ])

      assert_rejected(conn, "payment_not_reducible")
    end

    test "cash that was settled by a cancellation never moves through a reduction", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          cancel_operation(%{"occurred_on" => "2026-11-27"})
        ])

      assert %{"results" => [_, _, %{"retained_cents" => 10_000}]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 1_000})
        ])

      assert_rejected(conn, "payment_not_reducible")
    end

    test "rejects non-positive amounts with invalid_amount", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000})
        ])

      for {amount, index} <- Enum.with_index([nil, 0, -1_000, "1000", 1_000.0]) do
        conn =
          post_operations(conn, [
            reduce_operation(%{
              "operation_id" => "op-amount-#{index}",
              "amount_cents" => amount
            })
          ])

        assert_rejected(conn, "invalid_amount")
      end
    end

    test "rejects an amount exceeding the held cash with reduction_exceeds_held_cash", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000})
        ])

      conn =
        post_operations(conn, [
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 4_001})
        ])

      assert_rejected(conn, "reduction_exceeds_held_cash")

      # The rejection changed nothing.
      assert %{"revision" => 2, "cash_paid_cents" => 4_000} = fetch_group!(conn, "group-81")
      assert %{"cash_reduced_cents" => 0} = ledger(conn)
    end

    test "checks the revision before the other rules", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000}),
          reduce_operation(%{
            "operation_id" => "op-reduce",
            "amount_cents" => -1,
            "expected_revision" => 7
          })
        ])

      assert %{"results" => [_, _, stale]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 7,
               "actual_revision" => 2
             }
    end

    test "retries return the exact stored result and never rewrite the payment's result", %{
      conn: conn
    } do
      payment = record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000})
      reduce = reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 5_000})

      conn = post_operations(conn, [open_group_operation(), payment, reduce])
      assert %{"results" => [_, original_payment, original_reduce]} = json_response(conn, 200)

      conn = post_operations(conn, [reduce])
      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == original_reduce

      # Retrying the original payment replays its exact original result even
      # though the group's state has since changed.
      conn = post_operations(conn, [payment])
      assert %{"results" => [payment_replay]} = json_response(conn, 200)
      assert payment_replay == original_payment

      assert %{"revision" => 3, "cash_paid_cents" => 5_000} = fetch_group!(conn, "group-81")
      assert %{"cash_reduced_cents" => 5_000} = ledger(conn)
    end
  end

  describe "charge_back_payment" do
    test "reverses all held cash of one payment and reopens the outstanding deposit", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          record_payment_operation(%{"operation_id" => "op-other", "amount_cents" => 4_000}),
          charge_back_operation(%{"operation_id" => "op-chargeback"})
        ])

      assert %{"results" => [_, _, _, chargeback]} = json_response(conn, 200)

      assert chargeback == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 15_500,
               "revision" => 4
             }

      # The second payment's allocation keeps its room: it filled room-b
      # after room-a was full.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "cash_paid_cents" => 4_000}
               ],
               "cash_paid_cents" => 4_000
             } = fetch_group!(conn, "group-81")

      assert %{
               "cash_held_cents" => 4_000,
               "cash_charged_back_cents" => 10_000,
               "cash_reduced_cents" => 0
             } = ledger(conn)
    end

    test "moves refunded and retained portions to charged-back cash", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms",
            "occurred_on" => "2026-11-26",
            "room_ids" => ["room-a"]
          }),
          charge_back_operation(%{"operation_id" => "op-chargeback"})
        ])

      assert %{"results" => [_, _, _, chargeback]} = json_response(conn, 200)

      # 9_000 was refunded by the room settlement and 1_000 was still held.
      assert %{"charged_back_cents" => 10_000, "outstanding_deposit_cents" => 10_500} = chargeback

      assert %{
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_held_cents" => 0,
               "cash_charged_back_cents" => 10_000
             } = ledger(conn)
    end

    test "retracts converted principal, revokes the credit entitlement, and reports the shortfall",
         %{
           conn: conn
         } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          cancel_operation(%{
            "operation_id" => "op-cancel",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          open_group_operation(%{
            "operation_id" => "op-open-target",
            "group_id" => "group-target"
          }),
          apply_credit_operation(%{
            "operation_id" => "op-apply",
            "group_id" => "group-target",
            "amount_cents" => 11_000
          }),
          charge_back_operation(%{"operation_id" => "op-chargeback"})
        ])

      assert %{"results" => [_, _, _, _, _, chargeback]} = json_response(conn, 200)

      assert %{
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             } = chargeback

      # The converted cash moved to charged-back, and the lot's whole
      # entitlement is now unrecovered while it funds the active target.
      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_liability_cents" => 11_000,
               "credit_shortfall_cents" => 11_000
             } = ledger(conn, on: "2027-11-20")

      # The lot holds nothing available: the entitlement was revoked.
      assert %{"available_cents" => 0} = guest_credit(conn, "guest-22")

      # The chargeback changed only the original payment group's revision.
      assert %{"revision" => 2, "credit_paid_cents" => 11_000} =
               fetch_group!(conn, "group-target")

      # When the funded group settles refundably, the restoration is absorbed
      # by the shortfall: nothing becomes available again.
      conn =
        post_operations(conn, [
          cancel_operation(%{
            "operation_id" => "op-cancel-target",
            "group_id" => "group-target",
            "occurred_on" => "2026-11-26"
          })
        ])

      assert %{"results" => [%{"refunded_cents" => 0, "retained_cents" => 0}]} =
               json_response(conn, 200)

      assert %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0,
               "cash_charged_back_cents" => 10_000
             } = ledger(conn, on: "2027-11-20")

      assert %{"available_cents" => 0} = guest_credit(conn, "guest-22")
    end

    test "assigns entitlements that telescope across payments funding one lot", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 27_775},
        %{"room_id" => "room-b", "nightly_rate_cents" => 27_775}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-two",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => rooms
          }),
          record_payment_operation(%{
            "operation_id" => "op-pay-1",
            "group_id" => "group-two",
            "amount_cents" => 5_555
          }),
          record_payment_operation(%{
            "operation_id" => "op-pay-2",
            "group_id" => "group-two",
            "amount_cents" => 5_555
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel",
            "group_id" => "group-two",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          charge_back_operation(%{
            "operation_id" => "op-chargeback-2",
            "payment_operation_id" => "op-pay-2"
          }),
          charge_back_operation(%{
            "operation_id" => "op-chargeback-1",
            "payment_operation_id" => "op-pay-1"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The lot is worth 12_221. The first payment's entitlement is the bonus
      # value of its 5_555 (6_111); the second's is the remainder (6_110).
      # Both chargebacks remove their entitlement exactly: nothing remains and
      # no clawback is ever unrecovered.
      assert %{
               "available_cents" => 0,
               "lots" => []
             } = guest_credit(conn, "guest-22")

      assert %{"data" => data} =
               json_response(
                 get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-01"),
                 200
               )

      assert data == %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}

      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 11_110,
               "credit_shortfall_cents" => 0
             } = ledger(conn)
    end

    test "a partially applied lot keeps its shortfall against applied credit only", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 27_775},
        %{"room_id" => "room-b", "nightly_rate_cents" => 27_775}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-two",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => rooms
          }),
          record_payment_operation(%{
            "operation_id" => "op-pay-1",
            "group_id" => "group-two",
            "amount_cents" => 5_555
          }),
          record_payment_operation(%{
            "operation_id" => "op-pay-2",
            "group_id" => "group-two",
            "amount_cents" => 5_555
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel",
            "group_id" => "group-two",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          open_group_operation(%{
            "operation_id" => "op-open-target",
            "group_id" => "group-target"
          }),
          apply_credit_operation(%{
            "operation_id" => "op-apply",
            "group_id" => "group-target",
            "amount_cents" => 4_000
          }),
          charge_back_operation(%{
            "operation_id" => "op-chargeback-2",
            "payment_operation_id" => "op-pay-2"
          }),
          charge_back_operation(%{
            "operation_id" => "op-chargeback-1",
            "payment_operation_id" => "op-pay-1"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The second payment's entitlement (6_110) fit inside the lot's 8_221
      # remaining; the first's 6_111 could only remove the remaining 2_111,
      # leaving 4_000 unrecovered - exactly the credit the target holds.
      assert %{
               "credit_liability_cents" => 4_000,
               "credit_shortfall_cents" => 4_000
             } = ledger(conn, on: "2027-11-20")

      # A non-refundable settlement consumes the applied credit, so the
      # shortfall disappears with it.
      conn =
        post_operations(conn, [
          cancel_operation(%{
            "operation_id" => "op-cancel-target",
            "group_id" => "group-target",
            "occurred_on" => "2026-11-27"
          })
        ])

      assert %{"results" => [%{"retained_cents" => 0}]} = json_response(conn, 200)

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger(conn)
    end

    test "returns payment_not_chargeable for a target that cannot be reversed", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000}),
          record_payment_operation(%{"operation_id" => "op-excess", "amount_cents" => 999_999})
        ])

      assert %{"results" => [_, _, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "payment_exceeds_outstanding"

      # An unknown payment is not found; a recorded but non-payment or
      # rejected target is not chargeable.
      conn =
        post_operations(conn, [
          charge_back_operation(%{
            "operation_id" => "op-cb-unknown",
            "payment_operation_id" => "no-such-payment"
          })
        ])

      assert_rejected(conn, "operation_not_found")

      for payment_operation_id <- ["op-1001", "op-excess"] do
        conn =
          post_operations(conn, [
            charge_back_operation(%{
              "operation_id" => "op-cb-#{payment_operation_id}",
              "payment_operation_id" => payment_operation_id
            })
          ])

        assert_rejected(conn, "payment_not_chargeable")
      end

      # A fully reduced payment cannot be charged back either.
      conn =
        post_operations(conn, [
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 4_000}),
          charge_back_operation(%{"operation_id" => "op-cb-reduced"})
        ])

      assert %{"results" => [_, %{"code" => "payment_not_chargeable"}]} = json_response(conn, 200)
    end

    test "an already charged-back payment is not chargeable again", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000}),
          charge_back_operation(%{"operation_id" => "op-cb-1"}),
          charge_back_operation(%{"operation_id" => "op-cb-2"})
        ])

      assert %{"results" => [_, _, first, second]} = json_response(conn, 200)

      assert first["status"] == "applied"

      assert second == %{
               "operation_id" => "op-cb-2",
               "status" => "rejected",
               "code" => "payment_not_chargeable"
             }

      assert %{"cash_charged_back_cents" => 4_000} = ledger(conn)
    end

    test "a stale revision beats payment_not_chargeable", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000}),
          reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 4_000}),
          charge_back_operation(%{"operation_id" => "op-cb", "expected_revision" => 7})
        ])

      assert %{"results" => [_, _, _, stale]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "op-cb",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 7,
               "actual_revision" => 3
             }
    end

    test "chargebacks are durably idempotent", %{conn: conn} do
      op = charge_back_operation(%{"operation_id" => "op-cb"})

      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000}),
          op
        ])

      assert %{"results" => [_, _, original]} = json_response(conn, 200)

      conn = post_operations(conn, [op])
      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == original

      assert %{"revision" => 3} = fetch_group!(conn, "group-81")
      assert %{"cash_charged_back_cents" => 4_000} = ledger(conn)
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reconciles the current disposition of one payment", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10_000}),
          record_payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 4_000}),
          reduce_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay-1",
            "amount_cents" => 500
          }),
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms",
            "occurred_on" => "2026-11-27",
            "room_ids" => ["room-b"]
          }),
          charge_back_operation(%{
            "operation_id" => "op-cb",
            "payment_operation_id" => "op-pay-1"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The first payment recorded 10_000: 500 was reduced, 500 retained with
      # the room settlement and 9_000 was held until the chargeback reversed
      # it. The dispositions sum exactly to the recorded amount.
      assert %{"data" => statement} =
               json_response(get(conn, "/api/v1/payments/op-pay-1"), 200)

      assert statement == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 9_500
             }

      assert %{"data" => second} = json_response(get(conn, "/api/v1/payments/op-pay-2"), 200)

      assert second == %{
               "payment_operation_id" => "op-pay-2",
               "original_group_id" => "group-81",
               "recorded_cents" => 4_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 4_000,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      # The statements agree with the group and ledger views: the chargeback
      # carved the first payment's held cash from room-a, and room-b was
      # settled with its allocations retained.
      assert %{
               "cash_paid_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             } = fetch_group!(conn, "group-81")

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 9_500} = ledger(conn)
    end

    test "returns 404 operation_not_found for an unknown payment", %{conn: conn} do
      response = get(conn, "/api/v1/payments/never-seen")
      assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 payment_not_reconcilable for a record that is not an applied cash payment",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-excess", "amount_cents" => 999_999})
        ])

      assert %{"results" => [_, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "payment_exceeds_outstanding"

      for payment_operation_id <- ["op-1001", "op-excess"] do
        response = get(conn, "/api/v1/payments/#{payment_operation_id}")

        assert json_response(response, 422) == %{
                 "error" => %{"code" => "payment_not_reconcilable"}
               }
      end
    end

    test "reading a statement never changes state", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000})
        ])

      assert %{"data" => first} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{"data" => second} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)
      assert second == first

      assert %{"revision" => 2} = fetch_group!(conn, "group-81")
    end
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp cancel_rooms_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-25",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => @occurred_on,
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => @occurred_on,
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp assert_rejected(conn, code) do
    assert %{"results" => results} = json_response(conn, 200)
    result = List.last(results)

    assert result["status"] == "rejected"
    assert result["code"] == code
  end

  defp ledger(conn, opts \\ []) do
    query = if on = opts[:on], do: "?on=#{on}", else: ""
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger#{query}"), 200)
    data
  end

  defp guest_credit(conn, guest_id) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/guests/#{guest_id}/credit"), 200)
    data
  end
end
