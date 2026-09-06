defmodule GroupStayWeb.PaymentCorrectionsTest do
  use GroupStayWeb.ConnCase

  @issue_cancel_on "2026-11-20"
  # The last day the default flex-14 group cancels refundably.
  @refund_boundary "2026-11-26"
  # One day past the window: non-refundable.
  @late_cancel_on "2026-11-27"

  defp results(conn), do: conn |> json_response(200) |> Map.fetch!("results")

  defp group_data(conn, group_id) do
    conn |> get_group(group_id) |> json_response(200) |> Map.fetch!("data")
  end

  defp room(data, room_id), do: Enum.find(data["rooms"], &(&1["room_id"] == room_id))

  defp ledger_data(conn), do: conn |> get_ledger() |> json_response(200) |> Map.fetch!("data")

  defp statement(conn, payment_operation_id),
    do: conn |> get_payment(payment_operation_id) |> json_response(200) |> Map.fetch!("data")

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the outstanding deposit", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 10_000, %{"operation_id" => "op-target"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results(conn)

      conn =
        post_operations(conn, [
          reduce_cash_payment_operation("op-target", 1_500, %{"operation_id" => "op-reduce"})
        ])

      assert [
               %{
                 "operation_id" => "op-reduce",
                 "status" => "applied",
                 "payment_operation_id" => "op-target",
                 "group_id" => "group-81",
                 "amount_cents" => 1_500,
                 "outstanding_deposit_cents" => 11_000,
                 "revision" => 3
               }
             ] = results(conn)

      # The removal ate room-b's 1000 first, then 500 of room-a's 9000.
      data = group_data(conn, "group-81")
      assert %{"cash_paid_cents" => 8_500} = room(data, "room-a")
      assert %{"cash_paid_cents" => 0} = room(data, "room-b")

      assert %{
               "cash_held_cents" => 8_500,
               "cash_reduced_cents" => 1_500,
               "credit_shortfall_cents" => 0
             } = ledger_data(conn)

      assert %{"recorded_cents" => 10_000, "held_cents" => 8_500, "reduced_cents" => 1_500} =
               Map.take(statement(conn, "op-target"), [
                 "recorded_cents",
                 "held_cents",
                 "reduced_cents"
               ])
    end

    test "successive reductions compose and the complete remainder is a valid amount", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"}),
          reduce_cash_payment_operation("op-target", 2_400),
          reduce_cash_payment_operation("op-target", 3_600, %{"operation_id" => "op-rest"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "amount_cents" => 3_600}
             ] = results(conn)

      assert %{"cash_held_cents" => 0, "cash_reduced_cents" => 6_000} = ledger_data(conn)
    end

    test "rejects with reduction_exceeds_held_cash while a smaller positive amount could succeed",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"}),
          reduce_cash_payment_operation("op-target", 9_999, %{"operation_id" => "op-big"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "rejected",
                 "code" => "reduction_exceeds_held_cash",
                 "group_id" => "group-81"
               }
             ] = results(conn)

      # Nothing moved.
      assert %{"cash_held_cents" => 6_000, "cash_reduced_cents" => 0} = ledger_data(conn)

      assert %{"revision" => 2} = Map.take(group_data(conn, "group-81"), ["revision"])
    end

    test "rejects non-positive amounts with invalid_amount after target checks", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"})
        ])

      conn =
        post_operations(conn, [
          reduce_cash_payment_operation("op-target", 0, %{"operation_id" => "op-zero"}),
          reduce_cash_payment_operation("op-target", -5, %{"operation_id" => "op-neg"}),
          reduce_cash_payment_operation("op-target", "5", %{"operation_id" => "op-str"}),
          reduce_cash_payment_operation("op-target", nil, %{"operation_id" => "op-nil"})
        ])

      for result <- results(conn) do
        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end

      # A non-positive amount on an unknown target still reports the missing
      # operation first.
      conn =
        post_operations(conn, [
          reduce_cash_payment_operation("op-open-mystery", -5, %{"operation_id" => "op-x"})
        ])

      assert [%{"status" => "rejected", "code" => "operation_not_found"}] = results(conn)
    end

    test "rejects targets that can never accept a positive reduction", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{"operation_id" => "op-the-group"}),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-settled-away"}),
          cancel_operation("group-81", %{"occurred_on" => @refund_boundary}),
          reduce_cash_payment_operation("op-the-group", 100, %{"operation_id" => "op-not-payment"}),
          reduce_cash_payment_operation("op-settled-away", 100, %{
            "operation_id" => "op-nothing-held"
          }),
          reduce_cash_payment_operation("op-never-heard-of-it", 100, %{
            "operation_id" => "op-unknown"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_not_reducible"},
               %{"status" => "rejected", "code" => "payment_not_reducible"},
               %{"status" => "rejected", "code" => "operation_not_found"}
             ] = results(conn)
    end

    test "a rejected payment is not reducible either", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 999_999, %{"operation_id" => "op-rejected-pay"}),
          reduce_cash_payment_operation("op-rejected-pay", 100, %{"operation_id" => "op-red"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "rejected", "code" => "payment_not_reducible"}
             ] = results(conn)
    end

    test "retrying the original payment keeps returning its exact original result", %{conn: conn} do
      original =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"})
        ])
        |> results()
        |> Enum.at(1)

      conn =
        post_operations(conn, [reduce_cash_payment_operation("op-target", 6_000)])

      assert [%{"status" => "applied"}] = results(conn)

      retry_result =
        post_operations(conn, [
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"})
        ])
        |> results()
        |> hd()

      assert retry_result == original
      assert original["outstanding_deposit_cents"] == 13_500

      # And no cash reappeared anywhere.
      assert %{"cash_held_cents" => 0, "cash_reduced_cents" => 6_000} = ledger_data(conn)
    end

    test "the durable idempotency rules apply to reductions themselves", %{conn: conn} do
      operation = reduce_cash_payment_operation("target", 500, %{"operation_id" => "op-red"})

      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "target"}),
          operation
        ])

      assert [_open, _pay, applied] = results(conn)
      assert %{"status" => "applied", "amount_cents" => 500} = applied

      retry = post_operations(conn, [operation]) |> results() |> hd()
      assert retry == applied

      assert %{"cash_reduced_cents" => 500} = ledger_data(conn)

      variant =
        post_operations(conn, [
          reduce_cash_payment_operation("target", 501, %{"operation_id" => "op-red"})
        ])
        |> results()
        |> hd()

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = variant
    end

    test "checks expected_revision before domain rules", %{conn: conn} do
      operation =
        reduce_cash_payment_operation("target", -5, %{
          "operation_id" => "op-stale",
          "expected_revision" => 9
        })

      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "target"}),
          operation
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 9,
                 "actual_revision" => 2
               }
             ] = results(conn)
    end
  end

  describe "charge_back_payment" do
    test "reverses all held cash and bumps the group revision exactly once", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 10_000, %{"operation_id" => "op-target"}),
          charge_back_payment_operation("op-target", %{"operation_id" => "op-cb"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-cb",
                 "status" => "applied",
                 "payment_operation_id" => "op-target",
                 "group_id" => "group-81",
                 "charged_back_cents" => 10_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               }
             ] = results(conn)

      data = group_data(conn, "group-81")
      assert %{"cash_paid_cents" => 0} = room(data, "room-a")
      assert %{"cash_paid_cents" => 0} = room(data, "room-b")

      assert %{"deposit_paid_cents" => 0, "outstanding_deposit_cents" => 19_500} =
               Map.take(data, ["deposit_paid_cents", "outstanding_deposit_cents"])

      assert %{
               "cash_held_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_shortfall_cents" => 0
             } = ledger_data(conn)

      assert %{"held_cents" => 0, "charged_back_cents" => 10_000} =
               Map.take(statement(conn, "op-target"), ["held_cents", "charged_back_cents"])
    end

    test "works on cancelled groups and reclassifies settled history without reissuing it", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"}),
          cancel_operation("group-81", %{"occurred_on" => @refund_boundary}),
          charge_back_payment_operation("op-target", %{"operation_id" => "op-cb"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 6_000},
               %{"status" => "applied", "charged_back_cents" => 6_000, "revision" => 4}
             ] = results(conn)

      # The historical refund was not reversed or reissued — only its
      # classification changed.
      assert %{
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 6_000,
               "cash_held_cents" => 0
             } = ledger_data(conn)

      # A chargeback against a retained cancellation behaves identically.
      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "advance-group",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 15_000}]
          }),
          payment_operation("advance-group", 45_000, %{"operation_id" => "op-retained-pay"}),
          cancel_operation("advance-group", %{"occurred_on" => "2026-10-05"}),
          charge_back_payment_operation("op-retained-pay")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "retained_cents" => 45_000},
               %{"status" => "applied", "charged_back_cents" => 45_000}
             ] = results(conn)

      assert %{"cash_retained_cents" => 0, "cash_charged_back_cents" => 51_000} =
               ledger_data(conn)
    end

    test "excludes already-reduced portions from the reversal", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-target"}),
          reduce_cash_payment_operation("op-target", 1_000),
          charge_back_payment_operation("op-target")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "amount_cents" => 1_000},
               %{"status" => "applied", "charged_back_cents" => 5_000}
             ] = results(conn)

      assert %{"cash_reduced_cents" => 1_000, "cash_charged_back_cents" => 5_000} =
               ledger_data(conn)

      # Every disposition sums back to the recorded amount.
      assert %{
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 5_000
             } = statement(conn, "op-target")
    end

    test "rejects payments that were fully reduced or already charged back", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{"operation_id" => "op-the-group"}),
          payment_operation("group-81", 4_000, %{"operation_id" => "op-all-reduced"}),
          reduce_cash_payment_operation("op-all-reduced", 4_000),
          charge_back_payment_operation("op-all-reduced"),
          payment_operation("group-81", 2_000, %{"operation_id" => "op-twice"}),
          charge_back_payment_operation("op-twice"),
          charge_back_payment_operation("op-twice"),
          charge_back_payment_operation("op-the-group"),
          charge_back_payment_operation("op-missing")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_not_chargeable"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_not_chargeable"},
               %{"status" => "rejected", "code" => "payment_not_chargeable"},
               %{"status" => "rejected", "code" => "operation_not_found"}
             ] = results(conn)
    end

    test "revokes converted entitlements and reports the current shortfall", %{conn: conn} do
      conn = fund_credit_eater_group(conn)

      # Charging p1 back revokes its 4400 share; the lot balance holds none
      # of it (all credit sits applied), so it becomes unrecovered clawback.
      # The shortfall equals the clawback because that lot's credit still
      # covers active rooms; liability keeps including covered credit.
      conn = post_operations(conn, [charge_back_payment_operation("op-p1")])

      assert [%{"status" => "applied", "charged_back_cents" => 4_000}] = results(conn)

      assert %{"credit_shortfall_cents" => 4_400, "credit_liability_cents" => 21_450} =
               ledger_data(conn)

      # The funded group's state and revision never moved.
      assert %{"status" => "active", "revision" => 2, "credit_paid_cents" => 21_450} =
               Map.take(group_data(conn, "credit-eater"), [
                 "status",
                 "revision",
                 "credit_paid_cents"
               ])

      # A refundable settlement restores the applied credit: the clawback
      # absorbs its share first, so only the excess becomes available.
      conn =
        post_operations(conn, [
          cancel_operation("credit-eater", %{
            "operation_id" => "op-cancel-eater",
            "occurred_on" => "2027-03-01"
          })
        ])

      assert [%{"status" => "applied", "refunded_cents" => 0}] = results(conn)

      assert %{"available_cents" => 17_050} =
               conn
               |> get_guest_credit("claw-guest", on: "2027-03-01")
               |> json_response(200)
               |> Map.fetch!("data")

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 17_050} =
               ledger_data(conn)

      # Charging p2 back now removes its whole remaining entitlement cleanly.
      conn = post_operations(conn, [charge_back_payment_operation("op-p2")])

      assert [%{"status" => "applied", "charged_back_cents" => 15_500}] = results(conn)

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger_data(conn)

      assert %{"available_cents" => 0} =
               conn
               |> get_guest_credit("claw-guest", on: "2027-03-02")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "non-refundable settlement of applied credit dissolves the shortfall automatically", %{
      conn: conn
    } do
      conn = fund_credit_eater_group(conn)

      conn = post_operations(conn, [charge_back_payment_operation("op-p1")])
      assert [%{"status" => "applied"}] = results(conn)
      assert %{"credit_shortfall_cents" => 4_400} = ledger_data(conn)

      # Cancelling past the flex-30 window (2027-03-20 > 2027-03-02) is
      # non-refundable: the applied credit is consumed rather than restored.
      conn =
        post_operations(conn, [
          cancel_operation("credit-eater", %{
            "operation_id" => "op-forfeit-eater",
            "occurred_on" => "2027-03-20"
          })
        ])

      assert [%{"status" => "applied", "retained_cents" => 0}] = results(conn)

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger_data(conn)

      assert %{"available_cents" => 0} =
               conn
               |> get_guest_credit("claw-guest", on: "2027-03-21")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    # Two payments fund the default group fully; both convert into one lot
    # worth bonus(19500)=21450 with telescoping entitlements 4400 + 17050,
    # which is then redeemed entirely into an active later group.
    defp fund_credit_eater_group(conn) do
      conn =
        post_operations(conn, [
          open_operation(%{"guest_id" => "claw-guest"}),
          payment_operation("group-81", 4_000, %{"operation_id" => "op-p1"}),
          payment_operation("group-81", 15_500, %{"operation_id" => "op-p2"}),
          cancel_operation("group-81", %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "credit-eater",
            "guest_id" => "claw-guest",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-30",
            "rooms" => [%{"room_id" => "room-huge", "nightly_rate_cents" => 75_000}]
          }),
          apply_credit_operation("credit-eater", 21_450, %{"occurred_on" => "2027-02-10"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied", "revision" => 2}] =
               results(conn)

      conn
    end

    test "absorption precedes expiry: restored credit extinguishes clawback on a dead lot", %{
      conn: conn
    } do
      # One payment converts 6000 into a 6600 lot expiring 2027-11-21.
      # 150 is applied to a far-future active group; charging the payment
      # back leaves a 150 unrecovered clawback covering exactly that applied
      # slice.
      conn =
        post_operations(conn, [
          open_operation(%{"guest_id" => "absorb-guest"}),
          payment_operation("group-81", 6_000, %{"operation_id" => "op-src"}),
          cancel_operation("group-81", %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          }),
          open_operation(%{
            "group_id" => "small-group",
            "guest_id" => "absorb-guest",
            "occurred_on" => "2027-06-01",
            "arrival_on" => "2028-02-10",
            "departure_on" => "2028-02-12",
            "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 12_000}]
          }),
          apply_credit_operation("small-group", 150, %{"occurred_on" => "2027-06-10"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn = post_operations(conn, [charge_back_payment_operation("op-src")])

      assert [%{"status" => "applied", "charged_back_cents" => 6_000}] = results(conn)

      assert %{"credit_shortfall_cents" => 150, "credit_liability_cents" => 150} =
               ledger_data(conn)

      # Restoring the 150 after the lot's expiry extinguishes the clawback
      # before the expiry check; nothing becomes available and the liability
      # drops to zero. The flex-30 window (arrival minus 30 days) still makes
      # this refundable on 2028-01-05.
      conn =
        post_operations(conn, [
          cancel_operation("small-group", %{"occurred_on" => "2028-01-05"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger_data(conn)

      # The surviving 6450 balance sits dead on the expired lot.
      assert %{"available_cents" => 0, "lots" => []} =
               conn
               |> get_guest_credit("absorb-guest", on: "2028-01-05")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "is durably idempotent like every other operation", %{conn: conn} do
      operation = charge_back_payment_operation("target", %{"operation_id" => "op-cb-once"})

      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 3_000, %{"operation_id" => "target"}),
          operation
        ])

      assert [_open, _pay, applied] = results(conn)
      assert %{"status" => "applied", "charged_back_cents" => 3_000, "revision" => 3} = applied

      retry = post_operations(conn, [operation]) |> results() |> hd()
      assert retry == applied

      assert %{"cash_charged_back_cents" => 3_000} = ledger_data(conn)
    end

    test "checks expected_revision against the original payment's group", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 3_000, %{"operation_id" => "target"}),
          charge_back_payment_operation("target", %{
            "operation_id" => "op-stale-cb",
            "expected_revision" => 1
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = results(conn)
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition with all fields present, summing to recorded", %{conn: conn} do
      # Four rooms; one payment spans all of them.
      rooms = [
        %{"room_id" => "r1", "nightly_rate_cents" => 15_000},
        %{"room_id" => "r2", "nightly_rate_cents" => 17_500},
        %{"room_id" => "r3", "nightly_rate_cents" => 7_000},
        %{"room_id" => "r4", "nightly_rate_cents" => 10_000}
      ]

      # Deposits: 9000 / 10500 / 4200 / 6000.
      conn =
        post_operations(conn, [
          open_operation(%{"rooms" => rooms}),
          # Partially funds r1: 4000 of its 9000.
          payment_operation("group-81", 4_000, %{"operation_id" => "op-a"}),
          # Spans everything: 5000 finishes r1, then r2 (10500), r3 (4200),
          # and finally 3000 on r4.
          payment_operation("group-81", 22_700, %{"operation_id" => "op-x"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # The reduction comes off the newest slice first: r4's 3000 becomes 2000.
      conn =
        post_operations(conn, [
          reduce_cash_payment_operation("op-x", 1_000, %{"operation_id" => "op-cut"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      conn =
        post_operations(conn, [
          cancel_rooms_operation("group-81", ["r2"], %{
            "operation_id" => "op-refund-r2",
            "occurred_on" => @refund_boundary
          }),
          cancel_rooms_operation("group-81", ["r3"], %{
            "operation_id" => "op-convert-r3",
            "occurred_on" => @refund_boundary,
            "refund_method" => "hotel_credit"
          }),
          cancel_rooms_operation("group-81", ["r4"], %{
            "operation_id" => "op-retain-r4",
            "occurred_on" => @late_cancel_on
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      data = statement(conn, "op-x")

      assert %{
               "payment_operation_id" => "op-x",
               "original_group_id" => "group-81",
               "recorded_cents" => 22_700,
               "held_cents" => 5_000,
               "refunded_cents" => 10_500,
               "retained_cents" => 2_000,
               "converted_to_credit_cents" => 4_200,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             } = data

      dispositions =
        data
        |> Map.drop(["payment_operation_id", "original_group_id", "recorded_cents"])
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      assert dispositions == 22_700

      # Reading a statement never changes state.
      assert statement(conn, "op-x") == data

      assert %{"data" => %{"revision" => 7}} = get_group(conn, "group-81") |> json_response(200)

      # The group view agrees: only r1 stays active, still holding op-a's
      # 4000 beside op-x's 5000.
      gdata = group_data(conn, "group-81")

      assert %{"status" => "active"} = room(gdata, "r1")
      assert %{"cash_paid_cents" => 9_000} = Map.take(gdata, ["cash_paid_cents"])

      assert %{"outstanding_deposit_cents" => 0} =
               Map.take(gdata, ["outstanding_deposit_cents"])

      # The ledger view agrees too.
      assert %{
               "cash_held_cents" => 9_000,
               "cash_refunded_cents" => 10_500,
               "cash_retained_cents" => 2_000,
               "cash_converted_to_credit_cents" => 4_200,
               "cash_reduced_cents" => 1_000,
               "cash_charged_back_cents" => 0
             } = ledger_data(conn)
    end

    test "zero dispositions are present and unknown or unusable targets answer per contract", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(%{"operation_id" => "op-the-opener"}),
          payment_operation("group-81", 2_000, %{"operation_id" => "op-fresh"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert %{
               "payment_operation_id" => "op-fresh",
               "original_group_id" => "group-81",
               "recorded_cents" => 2_000,
               "held_cents" => 2_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             } = statement(conn, "op-fresh")

      conn = get_payment(conn, "op-missing-entirely")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      # A non-payment operation record exists but reconciles nothing.
      conn = get_payment(conn, "op-the-opener")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    test "a rejected payment record is not reconcilable", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 999_999, %{"operation_id" => "op-denied"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "rejected"}] = results(conn)

      conn = get_payment(conn, "op-denied")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end
end
