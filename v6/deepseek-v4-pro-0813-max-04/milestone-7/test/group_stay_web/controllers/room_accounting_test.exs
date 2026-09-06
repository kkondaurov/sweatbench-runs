defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  alias GroupStay.Deposits.{CashAllocation, CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Repo

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_group(conn, group_id),
    do: json_response(get(conn, ~p"/api/v1/groups/#{group_id}"), 200)["data"]

  defp get_operation(conn, operation_id),
    do: json_response(get(conn, ~p"/api/v1/operations/#{operation_id}"), 200)["data"]

  defp ledger(conn, params \\ %{}),
    do: json_response(get(conn, "/api/v1/ledger", params), 200)["data"]

  defp guest_credit(conn, guest_id, params \\ %{}),
    do: json_response(get(conn, "/api/v1/guests/#{guest_id}/credit", params), 200)["data"]

  defp statement(conn, payment_operation_id),
    do: json_response(get(conn, ~p"/api/v1/payments/#{payment_operation_id}"), 200)["data"]

  defp room_of(group, room_id), do: Enum.find(group["rooms"], &(&1["room_id"] == room_id))

  # A flexible source group fully paid with 10_000 cash, cancelled while
  # refundable with hotel credit. Produces one guest-22 lot of 11_000 cents.
  defp issue_credit_lot(conn) do
    source =
      open(%{
        "operation_id" => "op-source",
        "group_id" => "group-source",
        "guest_id" => "guest-22",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

    pay =
      payment(%{
        "operation_id" => "op-pay-source",
        "group_id" => "group-source",
        "amount_cents" => 10_000
      })

    credit_cancel =
      cancel(%{
        "operation_id" => "op-cancel-source",
        "group_id" => "group-source",
        "occurred_on" => "2027-02-01",
        "refund_method" => "hotel_credit"
      })

    batch_results(conn, [source, pay, credit_cancel])
  end

  describe "room-level accounting" do
    test "fills one room's deposit before moving to the next" do
      conn = build_conn()

      batch_results(conn, [open(), payment(%{"amount_cents" => 13_000})])

      group = get_group(conn, "group-81")

      assert room_of(group, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15_000,
               "status" => "active",
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0
             }

      assert room_of(group, "room-b")["cash_paid_cents"] == 4_000
      assert group["cash_paid_cents"] == 13_000
      assert group["deposit_paid_cents"] == 13_000
      assert group["outstanding_deposit_cents"] == 6_500
    end

    test "fills hotel credit into the rooms in their original order" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      batch_results(conn, [target, apply])

      group = get_group(conn, "group-target")
      assert room_of(group, "room-a")["credit_paid_cents"] == 9_000
      assert room_of(group, "room-b")["credit_paid_cents"] == 1_000
    end

    test "group totals describe active rooms only" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-sell-a",
          "room_ids" => ["room-a"]
        })

      batch_results(conn, [open(), payment(%{"amount_cents" => 10_000}), settle])

      group = get_group(conn, "group-81")

      assert group["status"] == "active"
      assert room_of(group, "room-a")["status"] == "cancelled"

      # room-b alone: 3 nights at 17_500, a 10_500 deposit, 1_000 held cash.
      assert group["lodging_total_cents"] == 52_500
      assert group["deposit_due_cents"] == 10_500
      assert group["cash_paid_cents"] == 1_000
      assert group["deposit_paid_cents"] == 1_000
      assert group["outstanding_deposit_cents"] == 9_500

      assert room_of(group, "room-a")["cash_paid_cents"] == 0
      assert room_of(group, "room-a")["credit_paid_cents"] == 0
    end
  end

  describe "settling selected rooms" do
    test "settles the selected room and leaves the rest untouched" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle-b",
          "room_ids" => ["room-b"]
        })

      results = batch_results(conn, [open(), payment(%{"amount_cents" => 13_000}), settle])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-settle-b",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 4_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert room_of(group, "room-b")["status"] == "cancelled"
      assert room_of(group, "room-a")["status"] == "active"
      assert room_of(group, "room-a")["cash_paid_cents"] == 9_000

      assert ledger(conn)["cash_held_cents"] == 9_000
      assert ledger(conn)["cash_refunded_cents"] == 4_000
    end

    test "returns cancelled room ids in the group's original order" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-b", "room-a"]
        })

      results = batch_results(conn, [open(), settle])

      assert Enum.at(results, 1)["cancelled_room_ids"] == ["room-a", "room-b"]
      assert get_group(conn, "group-81")["status"] == "cancelled"
    end

    test "rejects unusable room selections with invalid_rooms" do
      conn = build_conn()

      settle = cancel_rooms(%{"operation_id" => "op-a", "room_ids" => ["room-a"]})

      unknown = cancel_rooms(%{"operation_id" => "op-b", "room_ids" => ["room-z"]})
      duplicate = cancel_rooms(%{"operation_id" => "op-c", "room_ids" => ["room-a", "room-a"]})
      empty = cancel_rooms(%{"operation_id" => "op-d", "room_ids" => []})
      already = cancel_rooms(%{"operation_id" => "op-e", "room_ids" => ["room-a"]})

      results =
        batch_results(conn, [
          open(),
          settle,
          unknown,
          duplicate,
          empty,
          already
        ])

      assert Enum.at(results, 1)["status"] == "applied"
      assert Enum.at(results, 2)["code"] == "invalid_rooms"
      assert Enum.at(results, 3)["code"] == "invalid_rooms"
      assert Enum.at(results, 4)["code"] == "invalid_rooms"
      assert Enum.at(results, 5)["code"] == "invalid_rooms"
      assert get_group(conn, "group-81")["revision"] == 2
      assert room_of(get_group(conn, "group-81"), "room-a")["status"] == "cancelled"
    end

    test "rejects rooms belonging to another group" do
      conn = build_conn()

      other =
        open(%{
          "operation_id" => "op-other",
          "group_id" => "group-other",
          "guest_id" => "guest-23",
          "rooms" => [
            %{"room_id" => "room-z", "nightly_rate_cents" => 15_000}
          ]
        })

      foreign =
        cancel_rooms(%{
          "operation_id" => "op-foreign",
          "group_id" => "group-other",
          "room_ids" => ["room-a"]
        })

      results = batch_results(conn, [open(), other, foreign])

      assert Enum.at(results, 2)["code"] == "invalid_rooms"
    end

    test "computes the hotel-credit bonus once on the combined cash" do
      conn = build_conn()

      pay_a = payment(%{"operation_id" => "op-pay-a", "amount_cents" => 1_005})
      pay_b = payment(%{"operation_id" => "op-pay-b", "amount_cents" => 1_005})

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-a", "room-b"],
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [open(), pay_a, pay_b, settle])

      # Combined 2_010 -> 201 bonus. Bonus per room would give 202.
      assert Enum.at(results, 3)["credit_issued_cents"] == 2_211
      assert Enum.at(results, 3)["refunded_cents"] == 0
      assert Enum.at(results, 3)["retained_cents"] == 0

      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 2_211
      assert length(credit["lots"]) == 1
      assert hd(credit["lots"])["remaining_cents"] == 2_211

      assert get_group(conn, "group-81")["status"] == "cancelled"
    end

    test "issues no lot when only credit funds the selected rooms" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "group_id" => "group-target",
          "room_ids" => ["room-a"],
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [target, apply, settle])

      assert Enum.at(results, 2)["credit_issued_cents"] == 0

      # room-a's 9_000 credit returns to the original lot.
      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 10_000
      [lot] = credit["lots"]
      assert lot["source_operation_id"] == "op-cancel-source"
      assert lot["remaining_cents"] == 10_000
    end

    test "non-refundable cancellation of selected rooms retains their cash" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-a"],
          "occurred_on" => "2026-12-05"
        })

      results = batch_results(conn, [open(), payment(%{"amount_cents" => 10_000}), settle])

      assert Enum.at(results, 2)["refunded_cents"] == 0
      assert Enum.at(results, 2)["retained_cents"] == 9_000

      assert ledger(conn)["cash_retained_cents"] == 9_000
      assert get_group(conn, "group-81")["status"] == "active"
    end

    test "rejects hotel credit for non-refundable selected rooms" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-a"],
          "occurred_on" => "2026-12-05",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [open(), payment(), settle])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-settle",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = get_group(conn, "group-81")
      assert group["revision"] == 2
      assert room_of(group, "room-a")["status"] == "active"
      assert ledger(conn)["cash_held_cents"] == 10_000
    end

    test "cancelling the last active room cancels the group" do
      conn = build_conn()

      settle_a = cancel_rooms(%{"operation_id" => "op-a", "room_ids" => ["room-a"]})
      settle_b = cancel_rooms(%{"operation_id" => "op-b", "room_ids" => ["room-b"]})

      results = batch_results(conn, [open(), settle_a])

      assert Enum.at(results, 1)["status"] == "applied"
      assert get_group(conn, "group-81")["status"] == "active"

      results = batch_results(conn, [settle_b])

      assert Enum.at(results, 0)["status"] == "applied"
      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["lodging_total_cents"] == 0
      assert group["deposit_due_cents"] == 0
    end

    test "cancel_group settles only the remaining active rooms" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-a"]
        })

      full = cancel(%{"operation_id" => "op-cancel"})

      results = batch_results(conn, [open(), payment(%{"amount_cents" => 10_000}), settle, full])

      assert Enum.at(results, 2)["refunded_cents"] == 9_000

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert Enum.all?(group["rooms"], &(&1["status"] == "cancelled"))
    end

    test "restores only the cancelled room's applied credit" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      settle_b =
        cancel_rooms(%{
          "operation_id" => "op-settle-b",
          "group_id" => "group-target",
          "room_ids" => ["room-b"]
        })

      batch_results(conn, [target, apply, settle_b])

      # room-b's 1_000 returns to the lot; room-a still holds 9_000.
      assert guest_credit(conn, "guest-22")["available_cents"] == 2_000

      group = get_group(conn, "group-target")
      assert room_of(group, "room-a")["credit_paid_cents"] == 9_000

      settle_a =
        cancel_rooms(%{
          "operation_id" => "op-settle-a",
          "group_id" => "group-target",
          "room_ids" => ["room-a"]
        })

      batch_results(conn, [settle_a])

      assert guest_credit(conn, "guest-22")["available_cents"] == 11_000
    end

    test "honours expected_revision" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-a"],
          "expected_revision" => 1
        })

      results = batch_results(conn, [open(), payment(), settle])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-settle",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "retries return the exact original result" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle",
          "room_ids" => ["room-a"]
        })

      first = batch_results(conn, [open(), payment(), settle])
      again = batch_results(conn, [settle])

      assert again == [Enum.at(first, 2)]
      assert get_group(conn, "group-81")["revision"] == 3
    end
  end

  describe "reducing recorded cash" do
    test "removes held allocations in reverse fill order and reopens outstanding" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          payment(%{"amount_cents" => 13_000}),
          reduce(%{"amount_cents" => 5_000})
        ])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 11_500,
               "revision" => 3
             }

      group = get_group(conn, "group-81")

      # Reverse fill order drains room-b (last filled) before room-a.
      assert room_of(group, "room-b")["cash_paid_cents"] == 0
      assert room_of(group, "room-a")["cash_paid_cents"] == 8_000
      assert group["outstanding_deposit_cents"] == 11_500

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 13_000,
               "held_cents" => 8_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 5_000,
               "charged_back_cents" => 0
             }

      assert ledger(conn)["cash_held_cents"] == 8_000
      assert ledger(conn)["cash_reduced_cents"] == 5_000
    end

    test "successive reductions compose against the remaining held cash" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          payment(%{"amount_cents" => 13_000}),
          reduce(%{"operation_id" => "op-reduce-1", "amount_cents" => 3_000}),
          reduce(%{"operation_id" => "op-reduce-2", "amount_cents" => 5_000})
        ])

      assert Enum.at(results, 2)["status"] == "applied"
      assert Enum.at(results, 3)["amount_cents"] == 5_000
      assert Enum.at(results, 3)["outstanding_deposit_cents"] == 14_500

      assert statement(conn, "op-pay")["reduced_cents"] == 8_000
      assert statement(conn, "op-pay")["held_cents"] == 5_000
    end

    test "accepts a reduction equal to the complete remaining held portion" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          payment(%{"amount_cents" => 13_000}),
          reduce(%{"amount_cents" => 13_000})
        ])

      assert Enum.at(results, 2)["status"] == "applied"
      assert statement(conn, "op-pay")["held_cents"] == 0
      assert statement(conn, "op-pay")["reduced_cents"] == 13_000
    end

    test "rejects amounts above the held portion with reduction_exceeds_held_cash" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          payment(%{"amount_cents" => 13_000}),
          reduce(%{"amount_cents" => 13_001})
        ])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "reduction_exceeds_held_cash"
             }

      assert get_group(conn, "group-81")["revision"] == 2
      assert statement(conn, "op-pay")["reduced_cents"] == 0
    end

    test "rejects non-positive amounts with invalid_amount" do
      conn = build_conn()

      zero = reduce(%{"operation_id" => "op-zero", "amount_cents" => 0})
      negative = reduce(%{"operation_id" => "op-neg", "amount_cents" => -5})

      results = batch_results(conn, [open(), payment(), zero, negative])

      assert Enum.at(results, 2)["code"] == "invalid_amount"
      assert Enum.at(results, 3)["code"] == "invalid_amount"
    end

    test "rejects unknown, non-payment, and rejected targets" do
      conn = build_conn()

      over = payment(%{"operation_id" => "op-over", "amount_cents" => 19_501})

      missing_target = reduce(%{"payment_operation_id" => "no-such-payment"})

      non_payment =
        reduce(%{
          "operation_id" => "op-r1",
          "payment_operation_id" => "op-open",
          "amount_cents" => 1
        })

      rejected_payment =
        reduce(%{
          "operation_id" => "op-r2",
          "payment_operation_id" => "op-over",
          "amount_cents" => 1
        })

      gone_target =
        reduce(%{"operation_id" => "op-r3", "amount_cents" => 1_000})

      results = batch_results(conn, [open(), over, missing_target, non_payment, rejected_payment])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "operation_not_found"
             }

      assert Enum.at(results, 3)["code"] == "payment_not_reducible"
      assert Enum.at(results, 4)["code"] == "payment_not_reducible"

      # No durable payment record exists for op-pay in this scenario.
      assert batch_results(conn, [gone_target]) == [
               %{
                 "operation_id" => "op-r3",
                 "status" => "rejected",
                 "code" => "operation_not_found"
               }
             ]
    end

    test "settled cash is never reducible" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          payment(),
          cancel(),
          reduce(%{"amount_cents" => 1_000})
        ])

      assert Enum.at(results, 3)["code"] == "payment_not_reducible"
    end

    test "checks the payment group's revision before other rules" do
      conn = build_conn()

      stale =
        reduce(%{
          "operation_id" => "op-stale",
          "amount_cents" => 0,
          "expected_revision" => 1
        })

      results = batch_results(conn, [open(), payment(), stale])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "honours a matching expected_revision" do
      conn = build_conn()

      reduce_with = reduce(%{"amount_cents" => 2_000, "expected_revision" => 2})

      results = batch_results(conn, [open(), payment(), reduce_with])

      assert Enum.at(results, 2)["status"] == "applied"
      assert Enum.at(results, 2)["revision"] == 3
    end

    test "reductions retry idempotently and never rewrite the payment's result" do
      conn = build_conn()

      reduce_with = reduce(%{"amount_cents" => 2_000})

      first = batch_results(conn, [open(), payment(), reduce_with])
      original_payment_result = Enum.at(first, 1)

      again = batch_results(conn, [reduce_with])
      assert again == [Enum.at(first, 2)]

      replayed = batch_results(conn, [open(), payment()])
      assert Enum.at(replayed, 1) == original_payment_result
      assert get_operation(conn, "op-pay") == original_payment_result

      # Nothing was reapplied by the replay.
      assert statement(conn, "op-pay")["held_cents"] == 8_000
      assert get_group(conn, "group-81")["revision"] == 3
    end
  end

  describe "charging back a payment" do
    test "reverses held cash, reopens outstanding, and returns the result" do
      conn = build_conn()

      results = batch_results(conn, [open(), payment(), charge_back()])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-reverse",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert group["cash_paid_cents"] == 0
      assert room_of(group, "room-a")["cash_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10_000
    end

    test "reclassifies refunded cash even after the group is cancelled" do
      conn = build_conn()

      results = batch_results(conn, [open(), payment(), cancel(), charge_back()])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-reverse",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10_000

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
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

    test "reclassifies retained cash" do
      conn = build_conn()

      late = cancel(%{"occurred_on" => "2026-12-05"})

      batch_results(conn, [open(), payment(), late, charge_back()])

      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10_000
    end

    test "revokes telescoping credit entitlements in funding order" do
      conn = build_conn()

      pay_a = payment(%{"operation_id" => "op-pay-a", "amount_cents" => 1_000})

      pay_b =
        payment(%{"operation_id" => "op-pay-b", "amount_cents" => 9_500})

      credit_cancel = cancel(%{"refund_method" => "hotel_credit"})

      reverse_a =
        charge_back(%{
          "operation_id" => "op-reverse-a",
          "payment_operation_id" => "op-pay-a"
        })

      results = batch_results(conn, [open(), pay_a, pay_b, credit_cancel, reverse_a])

      # op-pay-a (1_000) funded first: entitlement 1_100 of the 11_550 lot.
      assert Enum.at(results, 4)["charged_back_cents"] == 1_000
      assert guest_credit(conn, "guest-22")["available_cents"] == 10_450

      reverse_b =
        charge_back(%{
          "operation_id" => "op-reverse-b",
          "payment_operation_id" => "op-pay-b"
        })

      batch_results(conn, [reverse_b])

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10_500
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "clawing back spent credit reports a shortfall against the funded groups" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply = apply_credit(%{"group_id" => "group-target", "amount_cents" => 4_000})

      results =
        batch_results(conn, [
          target,
          apply,
          charge_back(%{"payment_operation_id" => "op-pay-source"})
        ])

      assert Enum.at(results, 2)["charged_back_cents"] == 10_000

      # The lot's 7_000 remaining revoked; 4_000 becomes unrecovered clawback,
      # exactly matching the amount still applied to the active target.
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 4_000
      assert ledger(conn)["credit_liability_cents"] == 4_000

      # Groups funded by the affected credit are untouched.
      target_group = get_group(conn, "group-target")
      assert target_group["revision"] == 2
      assert target_group["credit_paid_cents"] == 4_000
      assert ledger(conn)["cash_charged_back_cents"] == 10_000
    end

    test "credit returning to a shortfalled lot is absorbed before availability" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 4_000
        })

      batch_results(conn, [
        target,
        apply,
        charge_back(%{"operation_id" => "op-reverse", "payment_operation_id" => "op-pay-source"})
      ])

      assert ledger(conn)["credit_shortfall_cents"] == 4_000

      settle =
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2027-02-01"
        })

      batch_results(conn, [settle])

      # The 4_000 restoration extinguishes the clawback instead of becoming
      # available credit again.
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "absorption happens before the lot's expiry" do
      conn = build_conn()

      # Two payments fund one group and convert into one 11_000 lot whose
      # entitlements are 5_500 each.
      source =
        open(%{
          "operation_id" => "op-source",
          "group_id" => "group-source",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      pay_a =
        payment(%{
          "operation_id" => "op-pay-source",
          "group_id" => "group-source",
          "amount_cents" => 5_000
        })

      pay_b =
        payment(%{
          "operation_id" => "op-pay-source-b",
          "group_id" => "group-source",
          "amount_cents" => 5_000
        })

      credit_cancel =
        cancel(%{
          "operation_id" => "op-cancel-source",
          "group_id" => "group-source",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit"
        })

      batch_results(conn, [source, pay_a, pay_b, credit_cancel])

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 6_000
        })

      batch_results(conn, [
        target,
        apply,
        charge_back(%{"operation_id" => "op-reverse", "payment_operation_id" => "op-pay-source"})
      ])

      # 5_500 entitlement against 5_000 remaining leaves 500 unrecovered;
      # the current shortfall is the lesser of that and the 6_000 applied.
      assert ledger(conn)["credit_shortfall_cents"] == 500
      assert ledger(conn)["cash_charged_back_cents"] == 5_000

      # The lot expired on 2028-02-02. The 6_000 restoration absorbs the 500
      # clawback before the expiry rules drop the remaining 5_500.
      settle =
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2028-02-05"
        })

      batch_results(conn, [settle])

      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
      assert guest_credit(conn, "guest-22")["lots"] == []
    end

    test "non-refundable settlement of shortfall credit clears the shortfall" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply = apply_credit(%{"group_id" => "group-target", "amount_cents" => 4_000})

      batch_results(conn, [
        target,
        apply,
        charge_back(%{"operation_id" => "op-reverse", "payment_operation_id" => "op-pay-source"})
      ])

      assert ledger(conn)["credit_shortfall_cents"] == 4_000

      late =
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2026-12-05"
        })

      batch_results(conn, [late])

      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "leaves previously reduced cash reduced" do
      conn = build_conn()

      batch_results(conn, [
        open(),
        payment(%{"amount_cents" => 13_000}),
        reduce(%{"amount_cents" => 5_000}),
        charge_back()
      ])

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 13_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 5_000,
               "charged_back_cents" => 8_000
             }

      assert ledger(conn)["cash_reduced_cents"] == 5_000
      assert ledger(conn)["cash_charged_back_cents"] == 8_000
    end

    test "rejects unusable charge-back targets with payment_not_chargeable" do
      conn = build_conn()

      over = payment(%{"operation_id" => "op-over", "amount_cents" => 19_501})

      results =
        batch_results(conn, [
          open(),
          over,
          charge_back(%{"operation_id" => "op-r1", "payment_operation_id" => "op-open"}),
          charge_back(%{"operation_id" => "op-r2", "payment_operation_id" => "op-over"}),
          charge_back(%{"operation_id" => "op-r3", "payment_operation_id" => "no-such-payment"})
        ])

      assert Enum.at(results, 2)["code"] == "payment_not_chargeable"
      assert Enum.at(results, 3)["code"] == "payment_not_chargeable"
      assert Enum.at(results, 4)["code"] == "operation_not_found"
    end

    test "a fully reduced payment cannot be charged back" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          payment(%{"amount_cents" => 13_000}),
          reduce(%{"amount_cents" => 13_000}),
          charge_back()
        ])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-reverse",
               "status" => "rejected",
               "code" => "payment_not_chargeable"
             }
    end

    test "an already charged-back payment cannot be charged back again" do
      conn = build_conn()

      reverse = charge_back()

      results = batch_results(conn, [open(), payment(), reverse])

      assert Enum.at(results, 2)["status"] == "applied"

      again = charge_back(%{"operation_id" => "op-reverse-again"})

      assert batch_results(conn, [again]) == [
               %{
                 "operation_id" => "op-reverse-again",
                 "status" => "rejected",
                 "code" => "payment_not_chargeable"
               }
             ]
    end

    test "charge-backs retry idempotently and never change other groups" do
      conn = build_conn()

      reverse = charge_back()

      first = batch_results(conn, [open(), payment(), reverse])

      assert batch_results(conn, [reverse]) == [Enum.at(first, 2)]
      assert get_group(conn, "group-81")["revision"] == 3
      assert batch_results(conn, [open(), payment()]) |> Enum.at(1) == Enum.at(first, 1)
      assert ledger(conn)["cash_charged_back_cents"] == 10_000
    end
  end

  describe "payment reconciliation" do
    test "returns a statement whose dispositions sum to the recorded amount" do
      conn = build_conn()

      batch_results(conn, [
        open(),
        payment(%{"amount_cents" => 13_000}),
        reduce(%{"amount_cents" => 2_000})
      ])

      statement = statement(conn, "op-pay")

      assert statement["payment_operation_id"] == "op-pay"
      assert statement["original_group_id"] == "group-81"
      assert statement["recorded_cents"] == 13_000

      dispositions = [
        statement["held_cents"],
        statement["refunded_cents"],
        statement["retained_cents"],
        statement["converted_to_credit_cents"],
        statement["reduced_cents"],
        statement["charged_back_cents"]
      ]

      assert dispositions == [11_000, 0, 0, 0, 2_000, 0]
      assert Enum.sum(dispositions) == statement["recorded_cents"]

      # Eight fields and nothing more.
      assert statement |> Map.keys() |> Enum.sort() == [
               "charged_back_cents",
               "converted_to_credit_cents",
               "held_cents",
               "original_group_id",
               "payment_operation_id",
               "recorded_cents",
               "reduced_cents",
               "refunded_cents",
               "retained_cents"
             ]
    end

    test "tracks each disposition of the payment across mixed-room settlements" do
      conn = build_conn()

      settle =
        cancel_rooms(%{
          "operation_id" => "op-settle-a",
          "room_ids" => ["room-a"],
          "occurred_on" => "2026-12-05"
        })

      batch_results(conn, [
        open(),
        payment(),
        settle,
        reduce(%{"amount_cents" => 1_000})
      ])

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 9_000,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             }
    end

    test "returns 404 operation_not_found for an unknown payment" do
      conn = build_conn()

      conn = get(conn, ~p"/api/v1/payments/no-such-payment")

      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 payment_not_reconcilable for non-payment and rejected records" do
      conn = build_conn()

      over = payment(%{"operation_id" => "op-over", "amount_cents" => 19_501})

      batch_results(conn, [open(), over])

      conn = build_conn()
      conn = get(conn, ~p"/api/v1/payments/op-open")
      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      conn = build_conn()
      conn = get(conn, ~p"/api/v1/payments/op-over")
      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    test "reading a statement never changes state" do
      conn = build_conn()

      batch_results(conn, [open(), payment()])

      first = statement(conn, "op-pay")
      again = statement(conn, "op-pay")

      assert again == first
      assert get_group(conn, "group-81")["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 10_000
      assert get_operation(conn, "op-pay")["amount_cents"] == 10_000
    end
  end

  describe "senior legacy funding" do
    defp insert_legacy_group do
      group =
        Repo.insert!(%Group{
          group_id: "group-legacy",
          guest_id: "guest-legacy",
          property_id: "ams-canal",
          booked_on: ~D[2026-10-01],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          status: "active",
          revision: 1
        })

      room_a =
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: "room-a",
          nightly_rate_cents: 15_000,
          status: "active",
          deposit_due_cents: 9_000
        })

      room_b =
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: "room-b",
          nightly_rate_cents: 17_500,
          status: "active",
          deposit_due_cents: 10_500
        })

      # All of the group's pre-release funding lives in one unattributed
      # senior block: 9_000 cash (fills room-a) plus a 2_000 credit
      # application from a pre-release lot.
      Repo.insert!(%CashAllocation{
        group_id: group.id,
        room_id: room_a.id,
        payment_operation_id: nil,
        amount_cents: 9_000
      })

      lot =
        Repo.insert!(%CreditLot{
          guest_id: "guest-legacy",
          source_operation_id: "cancel-legacy",
          remaining_cents: 8_000,
          expires_on: ~D[2028-01-01],
          unrecovered_clawback_cents: 0
        })

      Repo.insert!(%CreditApplication{
        group_id: group.id,
        credit_lot_id: lot.id,
        room_id: room_b.id,
        amount_cents: 2_000
      })

      %{group: group, room_a: room_a, room_b: room_b, lot: lot}
    end

    test "group reads expose the senior funding at room level" do
      conn = build_conn()

      insert_legacy_group()

      group = get_group(conn, "group-legacy")

      assert room_of(group, "room-a")["cash_paid_cents"] == 9_000
      assert room_of(group, "room-b")["credit_paid_cents"] == 2_000
      assert group["cash_paid_cents"] == 9_000
      assert group["credit_paid_cents"] == 2_000
      assert group["deposit_paid_cents"] == 11_000
      assert group["outstanding_deposit_cents"] == 8_500

      assert ledger(conn)["cash_held_cents"] == 9_000
      assert ledger(conn)["credit_liability_cents"] == 10_000
    end

    test "legacy funding has no operation identity and cannot be targeted" do
      conn = build_conn()

      insert_legacy_group()

      results =
        batch_results(conn, [
          reduce(%{"payment_operation_id" => "cancel-legacy", "amount_cents" => 1_000}),
          charge_back(%{
            "operation_id" => "op-reverse",
            "payment_operation_id" => "cancel-legacy"
          })
        ])

      assert Enum.at(results, 0)["code"] == "operation_not_found"
      assert Enum.at(results, 1)["code"] == "operation_not_found"
      assert get_group(conn, "group-legacy")["revision"] == 1
    end

    test "credit entitlements run the senior block first" do
      conn = build_conn()

      insert_legacy_group()

      # A durable payment of 1_000 lands after the senior block's 9_000.
      durable =
        payment(%{
          "operation_id" => "op-durable",
          "group_id" => "group-legacy",
          "amount_cents" => 1_000
        })

      credit_cancel =
        cancel(%{
          "operation_id" => "op-cancel-legacy-group",
          "group_id" => "group-legacy",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [durable, credit_cancel])

      # 10_000 cash converts to an 11_000 lot: f(9_000) = 9_900 for the
      # senior block, plus f(10_000) - f(9_000) = 1_100 for the payment.
      assert Enum.at(results, 1)["credit_issued_cents"] == 11_000

      credit = guest_credit(conn, "guest-legacy")
      assert credit["available_cents"] == 21_000

      reverse =
        charge_back(%{
          "operation_id" => "op-reverse-durable",
          "payment_operation_id" => "op-durable"
        })

      batch_results(conn, [reverse])

      credit = guest_credit(conn, "guest-legacy")
      [new_lot, old_lot] = credit["lots"]
      assert old_lot["remaining_cents"] == 10_000
      assert new_lot["remaining_cents"] == 9_900

      assert statement(conn, "op-durable")["charged_back_cents"] == 1_000
    end
  end
end
