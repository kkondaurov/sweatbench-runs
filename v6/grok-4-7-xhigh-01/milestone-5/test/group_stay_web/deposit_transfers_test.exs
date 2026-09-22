defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credits
  alias GroupStay.Credits.Allocation
  alias GroupStay.Credits.Lot
  alias GroupStay.Funding.CashAllocation
  alias GroupStay.Funding.OrderBackfill
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  import Ecto.Query

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "transfer_deposit" do
    test "moves newest funding first and fills destination rooms in order", %{conn: conn} do
      conn = open_pair(conn)
      {conn, _} = one(conn, payment_op("src", 120, %{"operation_id" => "pay-old"}))
      conn = issue_credit(conn, "guest-22", 30)
      {conn, _} = one(conn, credit_op("src", 30, %{"operation_id" => "use-credit"}))
      {conn, _} = one(conn, payment_op("src", 40, %{"operation_id" => "pay-new"}))

      before_ledger = ledger(conn)["data"]
      before_available = credit(conn, "guest-22")["available_cents"]
      lot = Repo.get_by!(Lot, source_operation_id: credit_source!())
      before_remaining = lot.remaining_cents
      before_expiry = lot.expires_on

      {conn, result} =
        one(
          conn,
          transfer_op("src", "dst", 55, %{
            "operation_id" => "move-55",
            "expected_revision" => 4,
            "destination_expected_revision" => 1
          })
        )

      assert result == %{
               "operation_id" => "move-55",
               "status" => "applied",
               "source_group_id" => "src",
               "destination_group_id" => "dst",
               "amount_cents" => 55,
               "source_outstanding_deposit_cents" => 65,
               "destination_outstanding_deposit_cents" => 85,
               "source_revision" => 5,
               "destination_revision" => 2
             }

      src = group(conn, "src")
      dst = group(conn, "dst")
      assert src["cash_paid_cents"] == 120
      assert src["credit_paid_cents"] == 15
      assert src["outstanding_deposit_cents"] == 65
      assert dst["cash_paid_cents"] == 40
      assert dst["credit_paid_cents"] == 15
      assert dst["outstanding_deposit_cents"] == 85
      assert dst["deposit_due_cents"] == 140

      assert Enum.at(src["rooms"], 0)["cash_paid_cents"] == 100
      assert Enum.at(src["rooms"], 0)["credit_paid_cents"] == 0
      assert Enum.at(src["rooms"], 1)["cash_paid_cents"] == 20
      assert Enum.at(src["rooms"], 1)["credit_paid_cents"] == 15
      assert Enum.at(dst["rooms"], 0)["cash_paid_cents"] == 40
      assert Enum.at(dst["rooms"], 0)["credit_paid_cents"] == 0
      assert Enum.at(dst["rooms"], 1)["cash_paid_cents"] == 0
      assert Enum.at(dst["rooms"], 1)["credit_paid_cents"] == 15

      assert cash_held("dst", "x", "pay-new") == 40
      assert cash_held("src", "b", "pay-old") == 20
      assert cash_held("src", "a", "pay-old") == 100
      assert credit_held("dst", credit_source!()) == 15
      assert credit_held("src", credit_source!()) == 15

      new_statement = payment(conn, "pay-new")

      assert new_statement["held_by_group"] == [
               %{"group_id" => "dst", "amount_cents" => 40}
             ]

      assert new_statement["held_cents"] == 40
      assert new_statement["original_group_id"] == "src"
      assert dispositions_sum(new_statement) == 40
      refute Map.has_key?(payment(conn, "pay-old"), "held_by_group")
      assert payment(conn, "pay-old")["held_cents"] == 120

      assert ledger(conn)["data"] == before_ledger
      assert credit(conn, "guest-22")["available_cents"] == before_available
      lot = Repo.get!(Lot, lot.id)
      assert lot.remaining_cents == before_remaining
      assert lot.expires_on == before_expiry
      assert lot.unrecovered_clawback_cents == 0

      {conn, again} = one(conn, transfer_op("src", "dst", 20, %{"operation_id" => "move-rest"}))
      assert again["status"] == "applied"
      assert again["amount_cents"] == 20
      assert cash_held("dst", "y", "pay-old") == 5
      assert cash_held("src", "b", "pay-old") == 15
      assert credit_held("dst", credit_source!()) == 30
      assert credit_held("src", credit_source!()) == 0

      old_statement = payment(conn, "pay-old")

      assert old_statement["held_by_group"] == [
               %{"group_id" => "dst", "amount_cents" => 5},
               %{"group_id" => "src", "amount_cents" => 115}
             ]

      assert Enum.sum(Enum.map(old_statement["held_by_group"], & &1["amount_cents"])) ==
               old_statement["held_cents"]

      assert ledger(conn)["data"] == before_ledger
    end

    test "rejects the operation in documented order and leaves state unchanged", %{conn: conn} do
      conn = open_pair(conn)
      {conn, _} = one(conn, payment_op("src", 40, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, open_other_guest())
      before = snapshot(conn, "src")
      dest_before = snapshot(conn, "dst")

      {conn, missing_source} =
        one(conn, transfer_op("gone", "dst", 10, %{"operation_id" => "missing-source"}))

      {conn, missing_dest} =
        one(conn, transfer_op("src", "gone", 10, %{"operation_id" => "missing-dest"}))

      {conn, missing_dest_stale_source} =
        one(
          conn,
          transfer_op("src", "gone", 10, %{
            "operation_id" => "missing-dest-stale",
            "expected_revision" => 1
          })
        )

      {conn, source_stale} =
        one(
          conn,
          transfer_op("src", "dst", -5, %{
            "operation_id" => "source-stale",
            "expected_revision" => 1,
            "destination_expected_revision" => 9,
            "amount_cents" => -5
          })
        )

      {conn, dest_stale} =
        one(
          conn,
          transfer_op("src", "dst", 0, %{
            "operation_id" => "dest-stale",
            "expected_revision" => 2,
            "destination_expected_revision" => 4
          })
        )

      {conn, same} =
        one(conn, transfer_op("src", "src", 10, %{"operation_id" => "same"}))

      {conn, other_guest} =
        one(conn, transfer_op("src", "other", 10, %{"operation_id" => "guest"}))

      assert missing_source["code"] == "group_not_found"
      assert missing_source["group_id"] == "gone"
      assert missing_dest["code"] == "group_not_found"
      assert missing_dest["group_id"] == "gone"
      assert missing_dest_stale_source["code"] == "group_not_found"
      assert missing_dest_stale_source["group_id"] == "gone"
      assert source_stale["code"] == "stale_revision"
      assert source_stale["group_id"] == "src"
      assert source_stale["expected_revision"] == 1
      assert source_stale["actual_revision"] == 2
      assert dest_stale["code"] == "stale_revision"
      assert dest_stale["group_id"] == "dst"
      assert dest_stale["expected_revision"] == 4
      assert dest_stale["actual_revision"] == 1
      assert same["code"] == "invalid_transfer"
      assert other_guest["code"] == "invalid_transfer"
      assert snapshot(conn, "src") == before
      assert snapshot(conn, "dst") == dest_before

      {conn, _} = one(conn, cancel_op("src", %{"operation_id" => "cancel-src"}))

      {conn, inactive_source} =
        one(conn, transfer_op("src", "dst", 10, %{"operation_id" => "inactive-src"}))

      assert inactive_source["code"] == "group_not_active"
      assert inactive_source["group_id"] == "src"

      {conn, _} = one(conn, cancel_op("dst", %{"operation_id" => "cancel-dst"}))

      {_conn, both_inactive} =
        one(
          conn,
          transfer_op("src", "dst", 10, %{
            "operation_id" => "both-inactive",
            "expected_revision" => group(conn, "src")["revision"]
          })
        )

      assert both_inactive["code"] == "group_not_active"
      assert both_inactive["group_id"] == "src"
    end

    test "checks amount and capacity after revisions and guest rules", %{conn: conn} do
      conn = open_pair(conn)
      {conn, _} = one(conn, payment_op("src", 40, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, open_op("old", %{"rooms" => [room("a", 500)]}))
      {conn, _} = one(conn, cancel_op("old", %{"operation_id" => "drop-old"}))

      {conn, inactive_dest} =
        one(
          conn,
          transfer_op("src", "old", -1, %{
            "operation_id" => "inactive-dest",
            "expected_revision" => group(conn, "src")["revision"],
            "destination_expected_revision" => group(conn, "old")["revision"]
          })
        )

      assert inactive_dest["code"] == "group_not_active"
      assert inactive_dest["group_id"] == "old"

      {conn, _} = one(conn, payment_op("dst", 120, %{"operation_id" => "fill-dst"}))
      before = snapshot(conn, "src")
      revision = group(conn, "src")["revision"]
      dest_revision = group(conn, "dst")["revision"]

      missing_amount =
        transfer_op("src", "dst", 1, %{"operation_id" => "no-amount"})
        |> Map.delete("amount_cents")

      {conn, no_amount} = one(conn, missing_amount)
      {conn, zero} = one(conn, transfer_op("src", "dst", 0, %{"operation_id" => "zero"}))

      {conn, text} =
        one(
          conn,
          transfer_op("src", "dst", 1, %{"operation_id" => "text", "amount_cents" => "4"})
        )

      {conn, over_held} =
        one(conn, transfer_op("src", "dst", 41, %{"operation_id" => "over-held"}))

      {conn, over_space} =
        one(conn, transfer_op("src", "dst", 30, %{"operation_id" => "over-space"}))

      {conn, bad_revision} =
        one(
          conn,
          transfer_op("src", "dst", 10, %{
            "operation_id" => "bad-rev",
            "destination_expected_revision" => "1"
          })
        )

      missing_ids =
        transfer_op("src", "dst", 10, %{"operation_id" => "no-ids"})
        |> Map.delete("destination_group_id")

      {conn, no_ids} = one(conn, missing_ids)

      assert no_amount["code"] == "invalid_operation"
      assert zero["code"] == "invalid_amount"
      assert text["code"] == "invalid_amount"
      assert over_held["code"] == "transfer_exceeds_held_funding"
      assert over_space["code"] == "transfer_exceeds_outstanding"
      assert bad_revision["code"] == "invalid_operation"
      assert no_ids["code"] == "invalid_operation"
      assert snapshot(conn, "src") == before
      assert group(conn, "src")["revision"] == revision
      assert group(conn, "dst")["revision"] == dest_revision
    end

    test "accepts an amount equal to held funding and outstanding deposit", %{conn: conn} do
      {conn, _} = one(conn, open_op("src", %{"rooms" => [room("a", 500)]}))
      {conn, _} = one(conn, open_op("dst", %{"rooms" => [room("a", 500)]}))
      {conn, _} = one(conn, payment_op("src", 40, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, payment_op("dst", 60, %{"operation_id" => "fill"}))

      {conn, moved} = one(conn, transfer_op("src", "dst", 40, %{"operation_id" => "exact"}))

      assert moved["status"] == "applied"
      assert moved["amount_cents"] == 40
      assert moved["source_outstanding_deposit_cents"] == 100
      assert moved["destination_outstanding_deposit_cents"] == 0
      assert group(conn, "src")["cash_paid_cents"] == 0
      assert group(conn, "dst")["cash_paid_cents"] == 100
      assert ledger(conn)["data"]["cash_held_cents"] == 100
    end

    test "is durably idempotent and visible to later operations in the batch", %{conn: conn} do
      op =
        transfer_op("src", "dst", 25, %{
          "operation_id" => "batched"
        })

      {conn, [opened_src, opened_dst, paid, moved]} =
        batch(conn, [
          open_op("src", %{"rooms" => [room("a", 500)]}),
          open_op("dst", %{"rooms" => [room("x", 500)]}),
          payment_op("src", 40, %{"operation_id" => "pay"}),
          op
        ])

      assert opened_src["status"] == "applied"
      assert opened_dst["status"] == "applied"
      assert paid["status"] == "applied"
      assert moved["status"] == "applied"
      assert moved["source_outstanding_deposit_cents"] == 85
      assert moved["destination_outstanding_deposit_cents"] == 75
      assert group(conn, "dst")["cash_paid_cents"] == 25

      {conn, replay} = one(conn, op)
      assert replay == moved
      assert group(conn, "src")["revision"] == moved["source_revision"]
      assert group(conn, "dst")["revision"] == moved["destination_revision"]
      assert payment(conn, "pay")["held_cents"] == 40

      assert json_response(get(conn, "/api/v1/operations/batched"), 200)["data"] == moved

      {conn, conflict} =
        one(conn, transfer_op("src", "dst", 10, %{"operation_id" => "batched"}))

      assert conflict["code"] == "operation_id_conflict"
      assert group(conn, "dst")["cash_paid_cents"] == 25

      rejected = transfer_op("src", "dst", 90, %{"operation_id" => "too-much"})
      {conn, first} = one(conn, rejected)
      assert first["code"] == "transfer_exceeds_held_funding"
      {conn, _} = one(conn, payment_op("src", 50, %{"operation_id" => "more"}))
      {conn, again} = one(conn, rejected)
      assert again == first
      assert group(conn, "src")["cash_paid_cents"] == 65
    end
  end

  describe "later settlement and corrections" do
    test "settles transferred cash under the destination policy", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("src", %{
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21",
            "rooms" => [room("a", 500)]
          })
        )

      {conn, _} =
        one(
          conn,
          open_op("dst", %{
            "arrival_on" => "2026-11-05",
            "departure_on" => "2026-11-06",
            "rooms" => [room("a", 500)]
          })
        )

      {conn, _} = one(conn, payment_op("src", 100, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, transfer_op("src", "dst", 100, %{"operation_id" => "move"}))

      {conn, retained} =
        one(
          conn,
          cancel_op("dst", %{"operation_id" => "keep", "occurred_on" => "2026-11-01"})
        )

      assert retained["retained_cents"] == 100
      assert retained["refunded_cents"] == 0
      assert retained["credit_issued_cents"] == 0
      assert group(conn, "src")["status"] == "active"
      assert group(conn, "src")["cash_paid_cents"] == 0
      assert ledger(conn)["data"]["cash_retained_cents"] == 100
      assert ledger(conn)["data"]["cash_held_cents"] == 0
      assert ledger(conn)["data"]["cash_refunded_cents"] == 0

      {conn, _} =
        one(
          conn,
          open_op("late", %{
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21",
            "rooms" => [room("a", 500)]
          })
        )

      {conn, _} = one(conn, payment_op("src", 80, %{"operation_id" => "bonus-pay"}))
      {conn, _} = one(conn, transfer_op("src", "late", 80, %{"operation_id" => "to-late"}))

      {conn, credited} =
        one(
          conn,
          cancel_op("late", %{
            "operation_id" => "to-credit",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      assert credited["credit_issued_cents"] == Credits.issued_amount(80)
      assert credited["refunded_cents"] == 0
      assert credited["retained_cents"] == 0
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 80
      assert credit(conn, "guest-22")["available_cents"] == Credits.issued_amount(80)
    end

    test "restores transferred credit to its original lot without a second bonus", %{conn: conn} do
      conn = open_pair(conn)
      conn = issue_credit(conn, "guest-22", 100)
      source = credit_source!()
      {conn, _} = one(conn, credit_op("src", 40, %{"operation_id" => "park"}))
      {conn, _} = one(conn, transfer_op("src", "dst", 40, %{"operation_id" => "move-credit"}))
      expires_on = Repo.get_by!(Lot, source_operation_id: source).expires_on
      liability = ledger(conn)["data"]["credit_liability_cents"]

      {conn, restored} =
        one(
          conn,
          cancel_op("dst", %{"operation_id" => "give-back", "occurred_on" => "2026-11-01"})
        )

      assert restored["refunded_cents"] == 0
      assert restored["credit_issued_cents"] == 0
      assert credit(conn, "guest-22")["available_cents"] == Credits.issued_amount(100)
      assert ledger(conn)["data"]["credit_liability_cents"] == liability
      lot = Repo.get_by!(Lot, source_operation_id: source)
      assert lot.expires_on == expires_on
      assert lot.remaining_cents == Credits.issued_amount(100)
      assert group(conn, "src")["credit_paid_cents"] == 0
    end

    test "consumes transferred credit on a non-refundable destination cancellation", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("src", %{
            "rooms" => [room("a", 500)],
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21"
          })
        )

      {conn, _} =
        one(
          conn,
          open_op("soon", %{
            "rooms" => [room("a", 500)],
            "arrival_on" => "2026-11-05",
            "departure_on" => "2026-11-06"
          })
        )

      conn = issue_credit(conn, "guest-22", 100)
      {conn, _} = one(conn, credit_op("src", 40, %{"operation_id" => "park"}))
      {conn, _} = one(conn, transfer_op("src", "soon", 40, %{"operation_id" => "move"}))
      liability = ledger(conn)["data"]["credit_liability_cents"]

      {conn, consumed} =
        one(
          conn,
          cancel_op("soon", %{"operation_id" => "consume", "occurred_on" => "2026-11-01"})
        )

      assert consumed["status"] == "applied"
      assert credit(conn, "guest-22")["available_cents"] == Credits.issued_amount(100) - 40
      assert ledger(conn)["data"]["credit_liability_cents"] == liability - 40
      assert group(conn, "src")["credit_paid_cents"] == 0
    end

    test "reductions and chargebacks follow held cash across groups", %{conn: conn} do
      conn = open_pair(conn)
      {conn, pay} = one(conn, payment_op("src", 100, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, transfer_op("src", "dst", 40, %{"operation_id" => "move"}))
      dest_revision = group(conn, "dst")["revision"]
      {conn, _} = one(conn, payment_op("dst", 10, %{"operation_id" => "dst-pay"}))
      assert group(conn, "dst")["revision"] == dest_revision + 1

      {conn, reduced} =
        one(
          conn,
          reduce_op("pay", 50, %{"operation_id" => "trim", "expected_revision" => 3})
        )

      assert reduced == %{
               "operation_id" => "trim",
               "status" => "applied",
               "payment_operation_id" => "pay",
               "group_id" => "src",
               "amount_cents" => 50,
               "outstanding_deposit_cents" => 150,
               "revision" => 4
             }

      assert group(conn, "dst")["revision"] == dest_revision + 2
      assert group(conn, "dst")["cash_paid_cents"] == 10
      assert group(conn, "dst")["outstanding_deposit_cents"] == 130
      assert group(conn, "src")["cash_paid_cents"] == 50
      assert cash_held("src", "a", "pay") == 50
      assert cash_held("dst", "x", "pay") == 0

      statement = payment(conn, "pay")

      assert statement["held_by_group"] == [
               %{"group_id" => "src", "amount_cents" => 50}
             ]

      assert statement["reduced_cents"] == 50
      assert statement["held_cents"] == 50
      assert dispositions_sum(statement) == 100
      {conn, replay_pay} = one(conn, payment_op("src", 100, %{"operation_id" => "pay"}))
      assert replay_pay == pay

      {conn, drained} = one(conn, reduce_op("pay", 50, %{"operation_id" => "rest"}))
      assert drained["status"] == "applied"
      assert drained["revision"] == 5
      assert group(conn, "dst")["revision"] == dest_revision + 2
      assert payment(conn, "pay")["held_by_group"] == []
      assert payment(conn, "pay")["held_cents"] == 0
      assert payment(conn, "pay")["reduced_cents"] == 100

      {conn, _} = one(conn, payment_op("src", 80, %{"operation_id" => "wide"}))
      {conn, _} = one(conn, transfer_op("src", "dst", 80, %{"operation_id" => "shift"}))
      source_revision = group(conn, "src")["revision"]
      held_revision = group(conn, "dst")["revision"]

      {conn, back} = one(conn, charge_op("wide", %{"operation_id" => "cb"}))
      assert back["group_id"] == "src"
      assert back["charged_back_cents"] == 80
      assert back["outstanding_deposit_cents"] == group(conn, "src")["outstanding_deposit_cents"]
      assert back["revision"] == source_revision + 1
      assert group(conn, "dst")["revision"] == held_revision + 1
      assert group(conn, "dst")["cash_paid_cents"] == 10
      assert group(conn, "src")["cash_paid_cents"] == 0
      assert payment(conn, "wide")["charged_back_cents"] == 80
      assert payment(conn, "wide")["held_cents"] == 0
      assert payment(conn, "wide")["held_by_group"] == []
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 80
      assert ledger(conn)["data"]["cash_held_cents"] == 10
    end

    test "chargeback reclassifies settled transferred cash without rewriting the payment", %{
      conn: conn
    } do
      {conn, _} =
        one(
          conn,
          open_op("src", %{
            "rooms" => [room("a", 400)],
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21"
          })
        )

      {conn, _} =
        one(
          conn,
          open_op("dst", %{
            "rooms" => [room("a", 500)],
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21"
          })
        )

      {conn, original} = one(conn, payment_op("src", 80, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, transfer_op("src", "dst", 80, %{"operation_id" => "move"}))

      {conn, _} =
        one(
          conn,
          cancel_op("dst", %{"operation_id" => "refund", "occurred_on" => "2026-11-01"})
        )

      dest_revision = group(conn, "dst")["revision"]
      {conn, back} = one(conn, charge_op("pay", %{"operation_id" => "cb"}))
      assert back["status"] == "applied"
      assert back["charged_back_cents"] == 80
      assert back["outstanding_deposit_cents"] == 80
      assert group(conn, "dst")["revision"] == dest_revision + 1
      assert group(conn, "dst")["status"] == "cancelled"
      assert ledger(conn)["data"]["cash_refunded_cents"] == 0
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 80
      assert payment(conn, "pay")["refunded_cents"] == 0
      assert payment(conn, "pay")["charged_back_cents"] == 80
      assert payment(conn, "pay")["held_by_group"] == []
      {_conn, replay} = one(conn, payment_op("src", 80, %{"operation_id" => "pay"}))
      assert replay == original
    end

    test "preserves original funding order when converted credit is clawed back", %{conn: conn} do
      conn = open_pair(conn)
      {conn, _} = one(conn, payment_op("src", 3, %{"operation_id" => "p1"}))
      {conn, _} = one(conn, payment_op("src", 3, %{"operation_id" => "p2"}))
      {conn, _} = one(conn, transfer_op("src", "dst", 6, %{"operation_id" => "move"}))

      {conn, cancelled} =
        one(
          conn,
          cancel_op("dst", %{
            "operation_id" => "convert",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      assert cancelled["credit_issued_cents"] == 7
      {conn, back} = one(conn, charge_op("p2", %{"operation_id" => "cb-p2"}))
      assert back["charged_back_cents"] == 3
      assert credit(conn, "guest-22")["available_cents"] == 3
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 3
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 3
      assert ledger(conn)["data"]["credit_shortfall_cents"] == 0
      assert group(conn, "src")["revision"] == back["revision"]
    end

    test "does not advance groups that only hold clawed-back credit", %{conn: conn} do
      conn = open_pair(conn)
      {conn, _} = one(conn, payment_op("src", 20, %{"operation_id" => "pay"}))

      {conn, _} =
        one(
          conn,
          cancel_op("src", %{
            "operation_id" => "issue",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      {conn, _} =
        one(
          conn,
          open_op("hold", %{
            "rooms" => [room("a", 500)],
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21"
          })
        )

      {conn, _} = one(conn, credit_op("hold", 10, %{"operation_id" => "spend"}))
      hold_revision = group(conn, "hold")["revision"]
      {conn, back} = one(conn, charge_op("pay", %{"operation_id" => "cb"}))
      assert back["status"] == "applied"
      assert group(conn, "hold")["revision"] == hold_revision
      assert group(conn, "hold")["credit_paid_cents"] == 10
      refute Map.has_key?(payment(conn, "pay"), "held_by_group")
    end
  end

  describe "allocation order backfill" do
    test "reconstructs creation order for funding recorded before order tracking", %{conn: conn} do
      conn = open_pair(conn)
      {conn, _} = one(conn, payment_op("src", 100, %{"operation_id" => "older"}))
      conn = issue_credit(conn, "guest-22", 40)
      {conn, _} = one(conn, credit_op("src", 40, %{"operation_id" => "middle"}))
      {conn, _} = one(conn, payment_op("src", 20, %{"operation_id" => "newer"}))

      Repo.update_all(CashAllocation, set: [order_lo: nil])
      Repo.update_all(Allocation, set: [order_lo: nil])
      assert :ok = OrderBackfill.run()

      {conn, moved} =
        one(conn, transfer_op("src", "dst", 15, %{"operation_id" => "after-backfill"}))

      assert moved["status"] == "applied"
      assert cash_held("dst", "x", "newer") == 15
      assert cash_held("src", "a", "older") == 100
      assert credit_held("src", credit_source!()) == 40

      assert payment(conn, "newer")["held_by_group"] == [
               %{"group_id" => "dst", "amount_cents" => 15},
               %{"group_id" => "src", "amount_cents" => 5}
             ]

      refute Map.has_key?(payment(conn, "older"), "held_by_group")
    end
  end

  defp open_pair(conn) do
    {conn, _} =
      one(
        conn,
        open_op("src", %{
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-21",
          "rooms" => [room("a", 500), room("b", 500)]
        })
      )

    {conn, opened} =
      one(
        conn,
        open_op("dst", %{
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-21",
          "property_id" => "ams-jordaan",
          "rooms" => [room("x", 200), room("y", 500)]
        })
      )

    assert opened["status"] == "applied"
    conn
  end

  defp open_other_guest do
    open_op("other", %{"guest_id" => "guest-9", "rooms" => [room("a", 500)]})
  end

  defp issue_credit(conn, guest_id, cash) do
    source = "src-credit"

    {conn, _} =
      one(
        conn,
        open_op(source, %{
          "operation_id" => "open-credit-source",
          "guest_id" => guest_id,
          "occurred_on" => "2026-09-01",
          "arrival_on" => "2026-12-28",
          "departure_on" => "2026-12-29",
          "rooms" => [room("a", cash * 5)]
        })
      )

    {conn, _} =
      one(
        conn,
        payment_op(source, cash, %{
          "operation_id" => "pay-credit-source",
          "occurred_on" => "2026-09-02"
        })
      )

    {conn, cancelled} =
      one(
        conn,
        cancel_op(source, %{
          "operation_id" => "cancel-credit-source",
          "occurred_on" => "2026-09-03",
          "refund_method" => "hotel_credit"
        })
      )

    assert cancelled["credit_issued_cents"] == Credits.issued_amount(cash)
    Process.put(:credit_source, "cancel-credit-source")
    conn
  end

  defp credit_source!, do: Process.get(:credit_source)

  defp cash_held(group_id, room_id, operation_id) do
    group = Repo.get_by!(Group, group_id: group_id)
    room = Repo.get_by!(Room, group_id: group.id, room_id: room_id)

    Repo.one(
      from a in CashAllocation,
        where:
          a.room_id == ^room.id and a.operation_id == ^operation_id and a.disposition == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp credit_held(group_id, source_operation_id) do
    group = Repo.get_by!(Group, group_id: group_id)
    lot = Repo.get_by!(Lot, source_operation_id: source_operation_id)

    Repo.one(
      from a in Allocation,
        where: a.group_id == ^group.id and a.credit_lot_id == ^lot.id,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp dispositions_sum(statement) do
    statement["held_cents"] + statement["refunded_cents"] + statement["retained_cents"] +
      statement["converted_to_credit_cents"] + statement["reduced_cents"] +
      statement["charged_back_cents"]
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch(conn, operations) do
    conn = post_batch(conn, operations)
    {conn, json_response(conn, 200)["results"]}
  end

  defp one(conn, operation) do
    {conn, [result]} = batch(conn, [operation])
    {conn, result}
  end

  defp group(conn, group_id) do
    json_response(get(conn, "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp ledger(conn) do
    json_response(get(conn, "/api/v1/ledger"), 200)
  end

  defp credit(conn, guest_id) do
    json_response(get(conn, "/api/v1/guests/#{URI.encode(guest_id)}/credit"), 200)["data"]
  end

  defp payment(conn, operation_id) do
    json_response(get(conn, "/api/v1/payments/#{operation_id}"), 200)["data"]
  end

  defp snapshot(conn, group_id) do
    data = group(conn, group_id)

    %{
      revision: data["revision"],
      status: data["status"],
      rooms: data["rooms"],
      due: data["deposit_due_cents"],
      paid: data["deposit_paid_cents"],
      cash: data["cash_paid_cents"],
      credit: data["credit_paid_cents"],
      ledger: ledger(conn)["data"]
    }
  end

  defp room(room_id, rate), do: %{"room_id" => room_id, "nightly_rate_cents" => rate}

  defp open_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [room("a", 15000)]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-#{group_id}-#{amount}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp credit_op(group_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}-#{amount}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-06",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp transfer_op(source_id, destination_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "transfer-#{source_id}-#{destination_id}-#{amount}",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-07",
        "source_group_id" => source_id,
        "destination_group_id" => destination_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reduce_op(payment_operation_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "reduce-#{payment_operation_id}-#{amount}",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-08",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp charge_op(payment_operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "charge-#{payment_operation_id}",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-09",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end
end
