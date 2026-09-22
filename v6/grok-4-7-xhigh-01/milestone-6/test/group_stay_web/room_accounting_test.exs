defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credits
  alias GroupStay.Credits.Lot
  alias GroupStay.Funding
  alias GroupStay.Funding.Backfill
  alias GroupStay.Funding.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "room funding" do
    test "fills active rooms in original order and exposes room balances", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("g", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [room("a", 500), room("b", 400), room("c", 250)]
          })
        )

      {conn, paid} = one(conn, payment_op("g", 130, %{"operation_id" => "cash-1"}))
      assert paid["outstanding_deposit_cents"] == 100
      assert paid["revision"] == 2

      conn = issue_credit(conn, "guest-22", 40)
      {conn, credited} = one(conn, credit_op("g", 40, %{"operation_id" => "use-credit"}))
      assert credited["outstanding_deposit_cents"] == 60
      assert credited["revision"] == 3

      data = group(conn, "g")

      assert data["rooms"] == [
               room_view("a", 500, 100, "active", 100, 0),
               room_view("b", 400, 80, "active", 30, 40),
               room_view("c", 250, 50, "active", 0, 0)
             ]

      assert data["lodging_total_cents"] == 1150
      assert data["deposit_due_cents"] == 230
      assert data["cash_paid_cents"] == 130
      assert data["credit_paid_cents"] == 40
      assert data["deposit_paid_cents"] == 170
      assert data["outstanding_deposit_cents"] == 60

      {conn, later} =
        one(
          conn,
          payment_op("g", 20, %{
            "operation_id" => "cash-2",
            "occurred_on" => "2026-10-01"
          })
        )

      assert later["status"] == "applied"
      rooms = group(conn, "g")["rooms"]
      assert Enum.at(rooms, 1)["cash_paid_cents"] == 40
      assert Enum.at(rooms, 1)["credit_paid_cents"] == 40
      assert Enum.at(rooms, 2)["cash_paid_cents"] == 10
      assert ledger(conn)["data"]["cash_held_cents"] == 150
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms in original order and leaves the others funded", %{conn: conn} do
      conn = funded(conn, "g")

      {conn, result} =
        one(
          conn,
          cancel_rooms_op("g", ["b", "a"], %{
            "operation_id" => "drop-rooms",
            "occurred_on" => "2026-11-01",
            "expected_revision" => 3
          })
        )

      assert result == %{
               "operation_id" => "drop-rooms",
               "status" => "applied",
               "group_id" => "g",
               "cancelled_room_ids" => ["a", "b"],
               "refunded_cents" => 140,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      data = group(conn, "g")
      assert data["status"] == "active"
      assert data["revision"] == 4
      assert data["lodging_total_cents"] == 250
      assert data["deposit_due_cents"] == 50
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 10
      assert data["deposit_paid_cents"] == 10
      assert data["outstanding_deposit_cents"] == 40

      assert data["rooms"] == [
               room_view("a", 500, 100, "cancelled", 0, 0),
               room_view("b", 400, 80, "cancelled", 0, 0),
               room_view("c", 250, 50, "active", 0, 10)
             ]

      assert ledger(conn)["data"]["cash_held_cents"] == 0
      assert ledger(conn)["data"]["cash_refunded_cents"] == 140
      assert ledger(conn)["data"]["credit_liability_cents"] == Credits.issued_amount(200)
    end

    test "bonuses selected cash once and restores only that credit", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("g", %{
            "guest_id" => "guest-22",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [room("a", 150), room("b", 150)]
          })
        )

      conn = issue_credit(conn, "guest-22", 100)
      {conn, _} = one(conn, payment_op("g", 3, %{"operation_id" => "p1"}))
      {conn, _} = one(conn, payment_op("g", 3, %{"operation_id" => "p2"}))
      {conn, _} = one(conn, credit_op("g", 20, %{"operation_id" => "use"}))

      {conn, result} =
        one(
          conn,
          cancel_rooms_op("g", ["b", "a"], %{
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit",
            "operation_id" => "partial-credit"
          })
        )

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == Credits.issued_amount(6)
      assert result["credit_issued_cents"] == 7
      assert group(conn, "g")["status"] == "cancelled"
      assert credit(conn, "guest-22")["available_cents"] == Credits.issued_amount(100) + 7

      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 106
      assert ledger(conn)["data"]["cash_held_cents"] == 0
    end

    test "unpaid deposit ceases to be due without inventing cash", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("g", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [room("a", 500), room("b", 500)]
          })
        )

      {conn, _} = one(conn, payment_op("g", 40))

      {conn, result} =
        one(conn, cancel_rooms_op("g", ["a"], %{"occurred_on" => "2026-11-01"}))

      assert result["refunded_cents"] == 40
      assert result["retained_cents"] == 0
      data = group(conn, "g")
      assert data["deposit_due_cents"] == 100
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 100
      assert data["status"] == "active"
    end

    test "rejects invalid room selections without changing state", %{conn: conn} do
      conn = funded(conn, "g")
      before = snapshot(conn, "g")

      {conn, empty} = one(conn, cancel_rooms_op("g", [], %{"operation_id" => "empty"}))
      {conn, dup} = one(conn, cancel_rooms_op("g", ["a", "a"], %{"operation_id" => "dup"}))
      {conn, missing} = one(conn, cancel_rooms_op("g", ["nope"], %{"operation_id" => "missing"}))

      {conn, mixed} =
        one(conn, cancel_rooms_op("g", ["a", "nope"], %{"operation_id" => "mixed"}))

      {conn, bad_type} =
        one(
          conn,
          cancel_rooms_op("g", ["a"], %{"operation_id" => "type", "room_ids" => "a"})
        )

      missing_ids =
        cancel_rooms_op("g", ["a"], %{"operation_id" => "absent"})
        |> Map.delete("room_ids")

      {conn, absent} = one(conn, missing_ids)

      {conn, bad_method} =
        one(
          conn,
          cancel_rooms_op("g", ["a"], %{
            "operation_id" => "voucher",
            "refund_method" => "voucher"
          })
        )

      assert empty["code"] == "invalid_rooms"
      assert dup["code"] == "invalid_rooms"
      assert missing["code"] == "invalid_rooms"
      assert mixed["code"] == "invalid_rooms"
      assert bad_type["code"] == "invalid_operation"
      assert absent["code"] == "invalid_operation"
      assert bad_method["code"] == "invalid_operation"
      assert snapshot(conn, "g") == before

      {conn, _} = one(conn, cancel_rooms_op("g", ["a"], %{"operation_id" => "once"}))

      {conn, again} =
        one(conn, cancel_rooms_op("g", ["a"], %{"operation_id" => "again"}))

      assert again["code"] == "invalid_rooms"
      assert group(conn, "g")["status"] == "active"

      {conn, _} = one(conn, cancel_op("g", %{"operation_id" => "rest"}))

      {_conn, inactive} =
        one(conn, cancel_rooms_op("g", ["c"], %{"operation_id" => "late"}))

      assert inactive["code"] == "group_not_active"
    end

    test "hotel credit is unavailable for a non-refundable partial cancel", %{conn: conn} do
      conn = funded(conn, "g")
      before = snapshot(conn, "g")

      {conn, rejected} =
        one(
          conn,
          cancel_rooms_op("g", ["a"], %{
            "occurred_on" => "2026-12-09",
            "refund_method" => "hotel_credit",
            "expected_revision" => 3
          })
        )

      assert rejected["code"] == "refund_method_not_available"
      assert snapshot(conn, "g") == before

      {conn, kept} =
        one(conn, cancel_rooms_op("g", ["b"], %{"occurred_on" => "2026-12-09"}))

      assert kept["retained_cents"] == 40
      assert kept["refunded_cents"] == 0
      assert kept["credit_issued_cents"] == 0
      assert group(conn, "g")["credit_paid_cents"] == 10
      assert ledger(conn)["data"]["cash_retained_cents"] == 40
      assert ledger(conn)["data"]["credit_liability_cents"] == Credits.issued_amount(200) - 40
    end

    test "stale revision is rejected before room and refund rules", %{conn: conn} do
      conn = funded(conn, "g")
      before = snapshot(conn, "g")

      {conn, stale} =
        one(
          conn,
          cancel_rooms_op("g", ["missing"], %{
            "operation_id" => "stale",
            "expected_revision" => 1,
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-12-09"
          })
        )

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 3
      assert snapshot(conn, "g") == before

      {_conn, missing} =
        one(
          conn,
          cancel_rooms_op("absent", ["a"], %{"expected_revision" => 1, "operation_id" => "gone"})
        )

      assert missing["code"] == "group_not_found"
    end

    test "cancel_group settles only the rooms that are still active", %{conn: conn} do
      conn = funded(conn, "g")
      {conn, _} = one(conn, cancel_rooms_op("g", ["a"], %{"occurred_on" => "2026-11-01"}))

      {conn, result} =
        one(
          conn,
          cancel_op("g", %{
            "operation_id" => "rest",
            "occurred_on" => "2026-11-02",
            "refund_method" => "cash"
          })
        )

      assert result["refunded_cents"] == 40
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 5
      assert group(conn, "g")["status"] == "cancelled"
      assert group(conn, "g")["deposit_due_cents"] == 0
      assert group(conn, "g")["cash_paid_cents"] == 0
      assert ledger(conn)["data"]["cash_refunded_cents"] == 140
      assert ledger(conn)["data"]["cash_held_cents"] == 0
      assert credit(conn, "guest-22")["available_cents"] == Credits.issued_amount(200)
    end

    test "retries return the original room cancellation without settling again", %{conn: conn} do
      conn = funded(conn, "g")
      op = cancel_rooms_op("g", ["c", "a"], %{"operation_id" => "same"})
      {conn, first} = one(conn, op)
      {conn, again} = one(conn, op)
      assert again == first
      assert group(conn, "g")["revision"] == 4
      assert ledger(conn)["data"]["cash_refunded_cents"] == first["refunded_cents"]
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g"))
      {conn, _} = one(conn, payment_op("g", 150, %{"operation_id" => "pay-150"}))
      {conn, _} = one(conn, payment_op("g", 30, %{"operation_id" => "pay-30"}))

      {conn, reduced} =
        one(
          conn,
          reduce_op("pay-150", 60, %{"operation_id" => "red-1", "expected_revision" => 3})
        )

      assert reduced == %{
               "operation_id" => "red-1",
               "status" => "applied",
               "payment_operation_id" => "pay-150",
               "group_id" => "g",
               "amount_cents" => 60,
               "outstanding_deposit_cents" => 80,
               "revision" => 4
             }

      rooms = group(conn, "g")["rooms"]
      assert Enum.at(rooms, 0)["cash_paid_cents"] == 90
      assert Enum.at(rooms, 1)["cash_paid_cents"] == 30

      {conn, again} = one(conn, reduce_op("pay-150", 90, %{"operation_id" => "red-2"}))
      assert again["status"] == "applied"
      assert again["outstanding_deposit_cents"] == 170
      assert group(conn, "g")["rooms"] |> Enum.at(0) |> Map.get("cash_paid_cents") == 0
      assert group(conn, "g")["cash_paid_cents"] == 30

      {conn, too_much} = one(conn, reduce_op("pay-150", 1, %{"operation_id" => "red-3"}))
      assert too_much["code"] == "payment_not_reducible"

      statement = payment(conn, "pay-150")
      assert statement["reduced_cents"] == 150
      assert statement["held_cents"] == 0
      assert statement["recorded_cents"] == 150
      assert dispositions_sum(statement) == 150
      assert ledger(conn)["data"]["cash_reduced_cents"] == 150
      assert ledger(conn)["data"]["cash_held_cents"] == 30
    end

    test "rejects amounts and targets with the documented codes", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g"))
      {conn, _} = one(conn, payment_op("g", 40, %{"operation_id" => "pay"}))
      before = snapshot(conn, "g")

      {conn, zero} = one(conn, reduce_op("pay", 0, %{"operation_id" => "zero"}))
      {conn, negative} = one(conn, reduce_op("pay", -5, %{"operation_id" => "neg"}))

      {conn, text} =
        one(conn, reduce_op("pay", 1, %{"operation_id" => "text", "amount_cents" => "4"}))

      {conn, over} = one(conn, reduce_op("pay", 41, %{"operation_id" => "over"}))
      {conn, missing} = one(conn, reduce_op("legacy-pay", 1, %{"operation_id" => "legacy"}))

      {conn, rejected_payment} =
        one(conn, payment_op("g", 0, %{"operation_id" => "bad-pay"}))

      assert rejected_payment["code"] == "invalid_amount"

      {conn, not_payment} = one(conn, reduce_op("bad-pay", 1, %{"operation_id" => "not-pay"}))
      {conn, open} = one(conn, reduce_op("open-g", 1, %{"operation_id" => "open"}))

      missing_amount =
        reduce_op("pay", 1, %{"operation_id" => "no-amount"})
        |> Map.delete("amount_cents")

      {conn, no_amount} = one(conn, missing_amount)

      assert zero["code"] == "invalid_amount"
      assert negative["code"] == "invalid_amount"
      assert text["code"] == "invalid_amount"
      assert over["code"] == "reduction_exceeds_held_cash"
      assert missing["code"] == "operation_not_found"
      assert not_payment["code"] == "payment_not_reducible"
      assert open["code"] == "payment_not_reducible"
      assert no_amount["code"] == "invalid_operation"
      assert snapshot(conn, "g") == before

      {conn, stale} =
        one(
          conn,
          reduce_op("pay", -1, %{"operation_id" => "stale", "expected_revision" => 1})
        )

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
      assert snapshot(conn, "g") == before

      {conn, _} = one(conn, cancel_op("g", %{"occurred_on" => "2026-11-01"}))
      {_conn, settled} = one(conn, reduce_op("pay", 10, %{"operation_id" => "settled"}))
      assert settled["code"] == "payment_not_reducible"
    end

    test "remembers a rejected reduction and conflicts on a different payload", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g"))
      rejected = reduce_op("missing-pay", 5, %{"operation_id" => "later"})
      {conn, first} = one(conn, rejected)
      assert first["code"] == "operation_not_found"

      {conn, _} = one(conn, payment_op("g", 5, %{"operation_id" => "missing-pay"}))
      {conn, again} = one(conn, rejected)
      assert again == first
      assert group(conn, "g")["cash_paid_cents"] == 5

      {conn, conflict} =
        one(conn, reduce_op("missing-pay", 4, %{"operation_id" => "later"}))

      assert conflict["code"] == "operation_id_conflict"
      assert payment(conn, "missing-pay")["held_cents"] == 5
    end

    test "does not rewrite the original payment and is itself idempotent", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g"))
      pay = payment_op("g", 40, %{"operation_id" => "pay"})
      {conn, original} = one(conn, pay)
      {conn, _} = one(conn, reduce_op("pay", 15, %{"operation_id" => "red"}))

      {conn, replay} = one(conn, pay)
      assert replay == original
      assert group(conn, "g")["cash_paid_cents"] == 25
      assert group(conn, "g")["revision"] == 3
      assert json_response(get(conn, "/api/v1/operations/pay"), 200)["data"] == original

      red = reduce_op("pay", 15, %{"operation_id" => "red"})
      {conn, again} = one(conn, red)
      assert again["amount_cents"] == 15
      assert group(conn, "g")["cash_paid_cents"] == 25
      assert payment(conn, "pay")["reduced_cents"] == 15
      assert payment(conn, "pay")["held_cents"] == 25
    end
  end

  describe "charge_back_payment" do
    test "reclassifies every remaining disposition and claws back telescoped credit", %{
      conn: conn
    } do
      {conn, _} = one(conn, two_room_group("g", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("g", 3, %{"operation_id" => "p1"}))
      {conn, _} = one(conn, payment_op("g", 3, %{"operation_id" => "p2"}))

      {conn, cancelled} =
        one(
          conn,
          cancel_op("g", %{
            "operation_id" => "to-credit",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      assert cancelled["credit_issued_cents"] == 7

      {conn, _} = one(conn, two_room_group("next", %{"guest_id" => "guest-22"}))
      before_revision = group(conn, "next")["revision"]
      {conn, _} = one(conn, credit_op("next", 5, %{"operation_id" => "spend"}))
      funded_revision = group(conn, "next")["revision"]

      {conn, back} =
        one(
          conn,
          charge_op("p2", %{"operation_id" => "cb-2", "expected_revision" => 4})
        )

      assert back == %{
               "operation_id" => "cb-2",
               "status" => "applied",
               "payment_operation_id" => "p2",
               "group_id" => "g",
               "charged_back_cents" => 3,
               "outstanding_deposit_cents" => 0,
               "revision" => 5
             }

      assert group(conn, "next")["revision"] == funded_revision
      assert group(conn, "next")["credit_paid_cents"] == 5
      assert group(conn, "g")["revision"] == 5
      assert before_revision == 1

      statement = payment(conn, "p2")
      assert statement["converted_to_credit_cents"] == 0
      assert statement["charged_back_cents"] == 3
      assert statement["recorded_cents"] == 3
      assert dispositions_sum(statement) == 3

      data = ledger(conn)["data"]
      assert data["cash_converted_to_credit_cents"] == 3
      assert data["cash_charged_back_cents"] == 3
      assert data["credit_shortfall_cents"] == 2
      assert data["credit_liability_cents"] == 5

      {conn, restored} =
        one(
          conn,
          cancel_op("next", %{"occurred_on" => "2026-11-20", "operation_id" => "give-back"})
        )

      assert restored["status"] == "applied"
      assert ledger(conn)["data"]["credit_shortfall_cents"] == 0
      assert ledger(conn)["data"]["credit_liability_cents"] == 3
      assert credit(conn, "guest-22")["available_cents"] == 3
      assert group(conn, "next")["revision"] == funded_revision + 1
    end

    test "legacy senior cash changes the later payment entitlement", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("g", %{
            "guest_id" => "guest-22",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [room("a", 500)]
          })
        )

      group_row = Repo.get_by!(Group, group_id: "g")
      room = Funding.active_rooms(group_row) |> hd()

      %CashAllocation{}
      |> CashAllocation.changeset(%{
        group_id: group_row.id,
        room_id: room.id,
        operation_id: nil,
        amount_cents: 4,
        sequence: 1,
        disposition: "held"
      })
      |> Repo.insert!()

      group_row
      |> Ecto.Changeset.change(%{cash_paid_cents: 4, deposit_paid_cents: 4})
      |> Repo.update!()

      {conn, _} = one(conn, payment_op("g", 1, %{"operation_id" => "tiny"}))

      {conn, _} =
        one(
          conn,
          cancel_op("g", %{
            "operation_id" => "convert",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      assert credit(conn, "guest-22")["available_cents"] == Credits.issued_amount(5)

      {conn, back} = one(conn, charge_op("tiny", %{"operation_id" => "cb"}))
      assert back["charged_back_cents"] == 1
      assert back["revision"] == 4
      assert credit(conn, "guest-22")["available_cents"] == 4
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 1
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 4
    end

    test "absorbs restored credit before expiry and non-refundable use clears shortfall", %{
      conn: conn
    } do
      {conn, _} =
        one(
          conn,
          open_op("src", %{
            "guest_id" => "guest-22",
            "occurred_on" => "2026-10-01",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21",
            "rooms" => [room("a", 500)]
          })
        )

      {conn, _} = one(conn, payment_op("src", 5, %{"operation_id" => "first"}))
      {conn, _} = one(conn, payment_op("src", 5, %{"operation_id" => "second"}))

      {conn, _} =
        one(
          conn,
          cancel_op("src", %{
            "operation_id" => "issue",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      expires_on = ~D[2027-11-02]

      {conn, _} =
        one(
          conn,
          open_op("hold", %{
            "guest_id" => "guest-22",
            "occurred_on" => "2026-10-03",
            "arrival_on" => "2027-11-20",
            "departure_on" => "2027-11-22",
            "rate_plan" => "flexible"
          })
        )

      {conn, _} =
        one(
          conn,
          credit_op("hold", 8, %{"operation_id" => "park", "occurred_on" => "2026-12-01"})
        )

      {conn, _} = one(conn, charge_op("second", %{"operation_id" => "claw"}))
      assert ledger(conn)["data"]["credit_shortfall_cents"] == 2
      assert Repo.get_by!(Lot, source_operation_id: "issue").unrecovered_clawback_cents == 2

      {conn, _} =
        one(
          conn,
          cancel_op("hold", %{
            "operation_id" => "expire-restore",
            "occurred_on" => Date.to_iso8601(expires_on),
            "refund_method" => "cash"
          })
        )

      lot = Repo.get_by!(Lot, source_operation_id: "issue")
      assert lot.unrecovered_clawback_cents == 0
      assert lot.remaining_cents == 0
      assert credit(conn, "guest-22", "2027-11-01")["available_cents"] == 0
      assert ledger(conn, "2027-11-01")["data"]["credit_liability_cents"] == 0
      assert ledger(conn)["data"]["credit_shortfall_cents"] == 0

      {conn, _} = one(conn, two_room_group("keep", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("keep", 10, %{"operation_id" => "fee"}))

      {conn, _} =
        one(
          conn,
          cancel_op("keep", %{
            "operation_id" => "fee-credit",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        )

      {conn, _} = one(conn, two_room_group("lose", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, credit_op("lose", 6, %{"operation_id" => "apply-fee"}))
      {conn, _} = one(conn, charge_op("fee", %{"operation_id" => "claw-fee"}))
      assert ledger(conn)["data"]["credit_shortfall_cents"] == 6

      {conn, _} =
        one(
          conn,
          cancel_op("lose", %{"occurred_on" => "2026-12-09", "operation_id" => "consume"})
        )

      assert ledger(conn)["data"]["credit_shortfall_cents"] == 0
      assert ledger(conn)["data"]["credit_liability_cents"] == 0
      assert Repo.get_by!(Lot, source_operation_id: "fee-credit").unrecovered_clawback_cents == 6
    end

    test "moves held, refunded, and retained cash without reopening settled history", %{
      conn: conn
    } do
      {conn, _} = one(conn, two_room_group("g"))
      {conn, _} = one(conn, payment_op("g", 120, %{"operation_id" => "wide"}))
      {conn, _} = one(conn, payment_op("g", 40, %{"operation_id" => "other"}))
      {conn, _} = one(conn, reduce_op("wide", 20, %{"operation_id" => "trim"}))

      {conn, _} =
        one(
          conn,
          cancel_rooms_op("g", ["b"], %{"occurred_on" => "2026-11-01", "operation_id" => "room-b"})
        )

      {conn, back} = one(conn, charge_op("wide", %{"operation_id" => "cb-wide"}))
      assert back["charged_back_cents"] == 100
      assert back["outstanding_deposit_cents"] == 100

      wide = payment(conn, "wide")
      assert wide["reduced_cents"] == 20
      assert wide["charged_back_cents"] == 100
      assert wide["held_cents"] == 0
      assert wide["refunded_cents"] == 0
      assert dispositions_sum(wide) == 120

      other = payment(conn, "other")
      assert other["refunded_cents"] == 40
      assert other["charged_back_cents"] == 0

      {conn, other_back} = one(conn, charge_op("other", %{"operation_id" => "cb-other"}))
      assert other_back["charged_back_cents"] == 40
      assert other_back["outstanding_deposit_cents"] == 100
      assert payment(conn, "other")["refunded_cents"] == 0
      assert payment(conn, "other")["charged_back_cents"] == 40

      data = ledger(conn)["data"]
      assert data["cash_reduced_cents"] == 20
      assert data["cash_charged_back_cents"] == 140
      assert data["cash_refunded_cents"] == 0
      assert data["cash_held_cents"] == 0

      assert data["cash_held_cents"] + data["cash_refunded_cents"] + data["cash_retained_cents"] +
               data["cash_converted_to_credit_cents"] + data["cash_reduced_cents"] +
               data["cash_charged_back_cents"] == 160
    end

    test "rejects payments that cannot be charged back and remembers the result", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g"))
      {conn, _} = one(conn, payment_op("g", 20, %{"operation_id" => "pay"}))
      {conn, _} = one(conn, payment_op("missing", 1, %{"operation_id" => "rejected-pay"}))
      before = snapshot(conn, "g")

      {conn, missing} = one(conn, charge_op("no-such", %{"operation_id" => "missing"}))
      {conn, rejected} = one(conn, charge_op("rejected-pay", %{"operation_id" => "rej"}))
      {conn, opened} = one(conn, charge_op("open-g", %{"operation_id" => "opened"}))

      {conn, stale} =
        one(conn, charge_op("pay", %{"operation_id" => "stale", "expected_revision" => 1}))

      assert missing["code"] == "operation_not_found"
      assert rejected["code"] == "payment_not_chargeable"
      assert opened["code"] == "payment_not_chargeable"
      assert stale["code"] == "stale_revision"
      assert snapshot(conn, "g") == before

      {conn, _} = one(conn, reduce_op("pay", 20, %{"operation_id" => "all"}))
      {conn, drained} = one(conn, charge_op("pay", %{"operation_id" => "drained"}))
      assert drained["code"] == "payment_not_chargeable"

      {conn, _} = one(conn, two_room_group("h"))
      {conn, _} = one(conn, payment_op("h", 10, %{"operation_id" => "whole"}))
      op = charge_op("whole", %{"operation_id" => "once"})
      {conn, first} = one(conn, op)
      {conn, replay} = one(conn, op)
      assert replay == first
      assert group(conn, "h")["revision"] == 3

      {_conn, second} = one(conn, charge_op("whole", %{"operation_id" => "twice"}))
      assert second["code"] == "payment_not_chargeable"
    end

    test "can charge back a cancelled group without changing funded groups", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("g", 50, %{"operation_id" => "paid"}))

      {conn, _} =
        one(conn, cancel_op("g", %{"occurred_on" => "2026-12-09", "operation_id" => "keep-fee"}))

      {conn, back} = one(conn, charge_op("paid", %{"operation_id" => "late-cb"}))
      assert back["status"] == "applied"
      assert back["charged_back_cents"] == 50
      assert back["outstanding_deposit_cents"] == 0
      assert group(conn, "g")["status"] == "cancelled"
      assert group(conn, "g")["revision"] == 4
      assert ledger(conn)["data"]["cash_retained_cents"] == 0
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 50
      assert payment(conn, "paid")["retained_cents"] == 0
      assert payment(conn, "paid")["charged_back_cents"] == 50
    end
  end

  describe "payment reconciliation" do
    test "returns the current disposition and does not change state", %{conn: conn} do
      {conn, _} = one(conn, two_room_group("g"))
      {conn, _} = one(conn, payment_op("g", 80, %{"operation_id" => "pay/17"}))
      revision = group(conn, "g")["revision"]
      before = ledger(conn)

      assert payment(conn, "pay/17") == %{
               "payment_operation_id" => "pay/17",
               "original_group_id" => "g",
               "recorded_cents" => 80,
               "held_cents" => 80,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert group(conn, "g")["revision"] == revision
      assert ledger(conn) == before

      assert json_response(get(conn, "/api/v1/payments/missing"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert json_response(get(conn, "/api/v1/payments/open-g"), 422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  describe "legacy funding backfill" do
    test "allocates unattributed cash and credit before durable records, ignoring occurred_on", %{
      conn: conn
    } do
      {conn, _} =
        one(
          conn,
          open_op("g", %{
            "guest_id" => "guest-22",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rate_plan" => "advance_purchase",
            "rooms" => [room("a", 50), room("b", 50)]
          })
        )

      group_row = Repo.get_by!(Group, group_id: "g")
      legacy_lot = insert_lot!("guest-22", "legacy-lot", 20, ~D[2026-09-01])
      durable_lot = insert_lot!("guest-22", "durable-lot", 15, ~D[2026-09-02])

      insert_credit!(group_row, legacy_lot, 20)
      insert_credit!(group_row, durable_lot, 15)

      group_row
      |> Ecto.Changeset.change(%{
        cash_paid_cents: 40,
        credit_paid_cents: 35,
        deposit_paid_cents: 75
      })
      |> Repo.update!()

      insert_record!("credit-op", "apply_hotel_credit", "g", 15, "2026-12-01")
      insert_record!("cash-op", "record_cash_payment", "g", 30, "2026-10-01")

      before_cash = Repo.get!(Group, group_row.id).cash_paid_cents
      before_credit = Repo.get!(Group, group_row.id).credit_paid_cents
      before_remaining = Repo.get!(Lot, legacy_lot.id).remaining_cents
      before_liability = ledger(conn)["data"]["credit_liability_cents"]

      assert :ok = Backfill.backfill_group(Repo.get!(Group, group_row.id))

      after_group = Repo.get!(Group, group_row.id)
      assert after_group.cash_paid_cents == before_cash
      assert after_group.credit_paid_cents == before_credit
      assert after_group.revision == group_row.revision
      assert Repo.get!(Lot, legacy_lot.id).remaining_cents == before_remaining
      assert ledger(conn)["data"]["credit_liability_cents"] == before_liability
      assert ledger(conn)["data"]["cash_held_cents"] == 40

      data = group(conn, "g")

      assert data["rooms"] == [
               room_view("a", 50, 50, "active", 15, 35),
               room_view("b", 50, 50, "active", 25, 0)
             ]

      {conn, reduced} = one(conn, reduce_op("cash-op", 10, %{"operation_id" => "trim-legacy"}))
      assert reduced["status"] == "applied"
      assert reduced["outstanding_deposit_cents"] == 35
      assert payment(conn, "cash-op")["held_cents"] == 20
      assert payment(conn, "cash-op")["reduced_cents"] == 10

      assert json_response(get(conn, "/api/v1/payments/not-a-record"), 404)["error"]["code"] ==
               "operation_not_found"
    end
  end

  defp funded(conn, group_id) do
    {conn, _} =
      one(
        conn,
        open_op(group_id, %{
          "guest_id" => "guest-22",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rate_plan" => "flexible",
          "rooms" => [room("a", 500), room("b", 400), room("c", 250)]
        })
      )

    conn = issue_credit(conn, "guest-22", 200)
    {conn, _} = one(conn, payment_op(group_id, 140, %{"operation_id" => "cash-#{group_id}"}))

    {conn, applied} =
      one(conn, credit_op(group_id, 50, %{"operation_id" => "credit-#{group_id}"}))

    assert applied["status"] == "applied"
    conn
  end

  defp issue_credit(conn, guest_id, cash) do
    source = "src-#{System.unique_integer([:positive])}"

    {conn, _} =
      one(
        conn,
        open_op(source, %{
          "operation_id" => "open-#{source}",
          "guest_id" => guest_id,
          "occurred_on" => "2026-09-01",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-21",
          "rate_plan" => "flexible",
          "rooms" => [room("a", cash * 5)]
        })
      )

    {conn, _} =
      one(
        conn,
        payment_op(source, cash, %{
          "operation_id" => "pay-#{source}",
          "occurred_on" => "2026-09-02"
        })
      )

    {conn, cancelled} =
      one(
        conn,
        cancel_op(source, %{
          "operation_id" => "cancel-#{source}",
          "occurred_on" => "2026-09-03",
          "refund_method" => "hotel_credit"
        })
      )

    assert cancelled["credit_issued_cents"] == Credits.issued_amount(cash)
    conn
  end

  defp insert_lot!(guest_id, source_operation_id, amount, issued_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount,
      original_cents: amount,
      expires_on: Date.add(issued_on, 366),
      issued_on: issued_on
    })
    |> Repo.insert!()
  end

  defp insert_credit!(group, lot, amount) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %GroupStay.Credits.Allocation{}
    |> Ecto.Changeset.change(%{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: amount,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp insert_record!(operation_id, type, group_id, amount, occurred_on) do
    submission =
      GroupStay.CanonicalJson.encode(%{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount
      })

    result =
      Jason.encode!(%{
        "operation_id" => operation_id,
        "status" => "applied",
        "group_id" => group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => 0,
        "revision" => 2
      })

    %Record{}
    |> Record.changeset(%{
      operation_id: operation_id,
      type: type,
      submission: submission,
      result: result
    })
    |> Repo.insert!()
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

  defp ledger(conn, on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"
    json_response(get(conn, path), 200)
  end

  defp credit(conn, guest_id, on \\ nil) do
    path = "/api/v1/guests/#{URI.encode(guest_id)}/credit"
    path = if on, do: path <> "?on=#{on}", else: path
    json_response(get(conn, path), 200)["data"]
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

  defp room_view(room_id, rate, deposit, status, cash, credit) do
    %{
      "room_id" => room_id,
      "nightly_rate_cents" => rate,
      "status" => status,
      "deposit_due_cents" => deposit,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit
    }
  end

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
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [room("a", 15000), room("b", 17500)]
      },
      overrides
    )
  end

  defp two_room_group(group_id, overrides \\ %{}) do
    open_op(
      group_id,
      Map.merge(
        %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rate_plan" => "flexible",
          "rooms" => [room("a", 500), room("b", 500)]
        },
        overrides
      )
    )
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
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

  defp cancel_rooms_op(group_id, room_ids, overrides) do
    Map.merge(
      %{
        "operation_id" => "rooms-#{group_id}-#{Enum.join(room_ids, "-")}",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "room_ids" => room_ids
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
