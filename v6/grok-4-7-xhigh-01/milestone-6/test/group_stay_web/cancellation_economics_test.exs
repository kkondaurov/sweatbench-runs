defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "policy versions" do
    test "flexible groups booked before 2027 keep a 14-day window", %{conn: conn} do
      {conn, _} =
        one(conn, open_op("old", %{"occurred_on" => "2026-12-31", "arrival_on" => "2027-06-01"}))

      data = group(conn, "old")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-05-18"
      assert data["booked_on"] == "2026-12-31"
    end

    test "flexible groups booked on or after 2027-01-01 use a 30-day window", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("boundary", %{"occurred_on" => "2027-01-01", "arrival_on" => "2027-06-01"})
        )

      {conn, _} =
        one(
          conn,
          open_op("later", %{"occurred_on" => "2027-04-02", "arrival_on" => "2027-08-15"})
        )

      assert group(conn, "boundary")["policy_version"] == "flex-30"
      assert group(conn, "boundary")["refundable_until"] == "2027-05-02"
      assert group(conn, "later")["policy_version"] == "flex-30"
      assert group(conn, "later")["refundable_until"] == "2027-07-16"
    end

    test "advance purchase is non-refundable regardless of booking date", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("ap", %{
            "occurred_on" => "2027-02-01",
            "rate_plan" => "advance_purchase",
            "arrival_on" => "2027-06-01",
            "rooms" => one_room(1000)
          })
        )

      data = group(conn, "ap")
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "rescheduling keeps the original policy and recomputes refundable_until", %{conn: conn} do
      {conn, _} =
        one(conn, open_op("old", %{"occurred_on" => "2026-12-31", "arrival_on" => "2026-12-20"}))

      {conn, moved} =
        one(conn, reschedule_op("old", "2027-06-01", %{"occurred_on" => "2026-12-31"}))

      assert moved["policy_version"] == "flex-14"
      assert moved["refundable_until"] == "2027-05-18"
      assert moved["new_arrival_on"] == "2027-06-01"
      assert moved["new_departure_on"] == "2027-06-04"
      assert group(conn, "old")["policy_version"] == "flex-14"
      assert group(conn, "old")["booked_on"] == "2026-12-31"
      assert group(conn, "old")["refundable_until"] == "2027-05-18"

      {conn, _} =
        one(conn, open_op("new", %{"occurred_on" => "2027-01-15", "arrival_on" => "2027-06-01"}))

      {conn, shifted} =
        one(conn, reschedule_op("new", "2027-03-11", %{"occurred_on" => "2027-01-20"}))

      assert shifted["policy_version"] == "flex-30"
      assert shifted["refundable_until"] == "2027-02-09"

      {conn, _} =
        one(
          conn,
          open_op("ap", %{
            "rate_plan" => "advance_purchase",
            "rooms" => one_room(1000),
            "occurred_on" => "2027-02-01"
          })
        )

      {_conn, ap_move} =
        one(conn, reschedule_op("ap", "2027-04-01", %{"occurred_on" => "2027-02-02"}))

      assert ap_move["policy_version"] == "advance-nonrefundable"
      assert ap_move["refundable_until"] == nil
    end

    test "cancellation on refundable_until is refundable and the next day is not", %{conn: conn} do
      {conn, _} = one(conn, open_op("flex14", %{"occurred_on" => "2026-10-03"}))
      {conn, _} = one(conn, payment_op("flex14", 800))

      {conn, on_until} =
        one(
          conn,
          cancel_op("flex14", %{"occurred_on" => "2026-11-26", "refund_method" => "cash"})
        )

      assert on_until["refunded_cents"] == 800
      assert on_until["retained_cents"] == 0
      assert on_until["credit_issued_cents"] == 0

      {conn, _} =
        one(
          conn,
          open_op("flex14-late", %{"occurred_on" => "2026-10-03", "operation_id" => "o2"})
        )

      {conn, _} = one(conn, payment_op("flex14-late", 800))

      {conn, after_until} =
        one(conn, cancel_op("flex14-late", %{"occurred_on" => "2026-11-27"}))

      assert after_until["refunded_cents"] == 0
      assert after_until["retained_cents"] == 800

      {conn, _} =
        one(
          conn,
          open_op("flex30", %{"occurred_on" => "2027-01-01", "arrival_on" => "2027-06-01"})
        )

      {conn, _} = one(conn, payment_op("flex30", 400))

      {conn, flex30_ok} =
        one(
          conn,
          cancel_op("flex30", %{"occurred_on" => "2027-05-02", "refund_method" => "cash"})
        )

      assert flex30_ok["refunded_cents"] == 400

      {conn, _} =
        one(
          conn,
          open_op("flex30-late", %{"occurred_on" => "2027-01-01", "arrival_on" => "2027-06-01"})
        )

      {conn, _} = one(conn, payment_op("flex30-late", 400))

      {_conn, flex30_late} =
        one(conn, cancel_op("flex30-late", %{"occurred_on" => "2027-05-03"}))

      assert flex30_late["retained_cents"] == 400
      assert flex30_late["refunded_cents"] == 0
    end
  end

  describe "hotel credit issuance" do
    test "converts refundable cash into a bonus lot and moves it out of held cash", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("g", %{
            "guest_id" => "guest-22",
            "occurred_on" => "2026-10-03",
            "arrival_on" => "2027-06-01"
          })
        )

      {conn, _} = one(conn, payment_op("g", 5000))

      {conn, result} =
        one(
          conn,
          cancel_op("g", %{
            "operation_id" => "cancel-17",
            "occurred_on" => "2027-05-02",
            "refund_method" => "hotel_credit"
          })
        )

      assert result == %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "g",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             }

      cancelled = group(conn, "g")
      assert cancelled["status"] == "cancelled"
      assert cancelled["cash_paid_cents"] == 0
      assert cancelled["deposit_paid_cents"] == 0
      assert cancelled["outstanding_deposit_cents"] == 0

      assert credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5500,
                   "expires_on" => "2028-05-02"
                 }
               ]
             }

      assert credit(conn, "guest-22", "2028-05-01")["available_cents"] == 5500
      assert credit(conn, "guest-22", "2028-05-02")["lots"] == []

      assert ledger(conn, "2028-05-01")["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 5500,
               "credit_shortfall_cents" => 0
             }

      assert ledger(conn, "2028-05-02")["data"]["credit_liability_cents"] == 0
      assert ledger(conn, "2028-05-02")["data"]["cash_converted_to_credit_cents"] == 5000
    end

    test "rounds the bonus separately and still issues a lot when the bonus is zero", %{
      conn: conn
    } do
      {conn, _} = one(conn, open_op("half", %{"guest_id" => "g-half"}))
      {conn, _} = one(conn, payment_op("half", 5))

      {conn, half} =
        one(
          conn,
          cancel_op("half", %{"occurred_on" => "2026-11-01", "refund_method" => "hotel_credit"})
        )

      assert half["credit_issued_cents"] == 6
      assert half["refunded_cents"] == 0
      assert half["retained_cents"] == 0
      assert credit(conn, "g-half")["available_cents"] == 6

      {conn, _} = one(conn, open_op("flat", %{"guest_id" => "g-flat"}))
      {conn, _} = one(conn, payment_op("flat", 4))

      {conn, flat} =
        one(
          conn,
          cancel_op("flat", %{"occurred_on" => "2026-11-01", "refund_method" => "hotel_credit"})
        )

      assert flat["credit_issued_cents"] == 4

      assert credit(conn, "g-flat")["lots"] == [
               %{
                 "source_operation_id" => "cancel-flat",
                 "remaining_cents" => 4,
                 "expires_on" => "2027-11-02"
               }
             ]

      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 9
      assert ledger(conn)["data"]["credit_liability_cents"] == 10
    end

    test "omitted, null, and explicit cash refunds stay cash and issue no credit", %{conn: conn} do
      {conn, _} = one(conn, open_op("omit", %{"guest_id" => "cash-guest"}))
      {conn, _} = one(conn, payment_op("omit", 300))
      {conn, omitted} = one(conn, cancel_op("omit", %{"occurred_on" => "2026-11-01"}))
      assert omitted["refunded_cents"] == 300
      assert omitted["credit_issued_cents"] == 0

      {conn, _} = one(conn, open_op("nulled", %{"guest_id" => "cash-guest"}))
      {conn, _} = one(conn, payment_op("nulled", 200))

      {conn, nulled} =
        one(
          conn,
          cancel_op("nulled", %{"occurred_on" => "2026-11-01", "refund_method" => nil})
        )

      assert nulled["refunded_cents"] == 200
      assert nulled["credit_issued_cents"] == 0

      {conn, _} = one(conn, open_op("explicit", %{"guest_id" => "cash-guest"}))
      {conn, _} = one(conn, payment_op("explicit", 100))

      {_conn, explicit} =
        one(
          conn,
          cancel_op("explicit", %{"occurred_on" => "2026-11-01", "refund_method" => "cash"})
        )

      assert explicit["refunded_cents"] == 100
      assert explicit["credit_issued_cents"] == 0
      assert credit(conn, "cash-guest")["lots"] == []

      assert ledger(conn)["data"]["cash_refunded_cents"] == 600
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 0
    end

    test "hotel credit is rejected for non-refundable cancellations and leaves the group active",
         %{
           conn: conn
         } do
      {conn, _} = one(conn, open_op("late"))
      {conn, _} = one(conn, payment_op("late", 700))
      before = snapshot(conn, "late")

      {conn, late} =
        one(
          conn,
          cancel_op("late", %{
            "occurred_on" => "2026-12-01",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          })
        )

      assert late == %{
               "operation_id" => "cancel-late",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert snapshot(conn, "late") == before
      assert group(conn, "late")["status"] == "active"
      assert credit(conn, "guest-22")["available_cents"] == 0

      {conn, _} =
        one(
          conn,
          open_op("ap", %{
            "rate_plan" => "advance_purchase",
            "rooms" => one_room(1000),
            "guest_id" => "ap-guest"
          })
        )

      {conn, _} = one(conn, payment_op("ap", 400))

      {conn, ap} =
        one(
          conn,
          cancel_op("ap", %{"occurred_on" => "2026-10-04", "refund_method" => "hotel_credit"})
        )

      assert ap["code"] == "refund_method_not_available"
      assert group(conn, "ap")["status"] == "active"
      assert group(conn, "ap")["revision"] == 2

      {conn, followed} =
        one(
          conn,
          cancel_op("late", %{"operation_id" => "cash-later", "occurred_on" => "2026-12-01"})
        )

      assert followed["status"] == "applied"
      assert followed["retained_cents"] == 700
      assert followed["revision"] == 3
      assert group(conn, "late")["status"] == "cancelled"
    end

    test "a stale revision is rejected before the refund method rule", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      {conn, _} = one(conn, payment_op("g", 100))
      before = snapshot(conn, "g")

      {conn, stale} =
        one(
          conn,
          cancel_op("g", %{
            "occurred_on" => "2026-12-09",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          })
        )

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
      assert snapshot(conn, "g") == before

      {_conn, missing} =
        one(
          conn,
          cancel_op("absent", %{"refund_method" => "hotel_credit", "expected_revision" => 1})
        )

      assert missing["code"] == "group_not_found"
    end

    test "an unusable refund method is an invalid operation and does not cancel", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      before = snapshot(conn, "g")

      {conn, bad} =
        one(conn, cancel_op("g", %{"refund_method" => "voucher", "occurred_on" => "2026-11-01"}))

      assert bad["code"] == "invalid_operation"
      assert snapshot(conn, "g") == before

      {conn, stale_bad} =
        one(
          conn,
          cancel_op("g", %{
            "operation_id" => "stale",
            "refund_method" => "voucher",
            "expected_revision" => 4
          })
        )

      assert stale_bad["code"] == "stale_revision"
      assert group(conn, "g")["status"] == "active"
    end

    test "hotel credit uses the fixed window, including after the booking cutoff", %{conn: conn} do
      {conn, _} =
        one(
          conn,
          open_op("old-window", %{"occurred_on" => "2026-12-31", "arrival_on" => "2027-06-01"})
        )

      {conn, _} = one(conn, payment_op("old-window", 100))

      {conn, accepted} =
        one(
          conn,
          cancel_op("old-window", %{
            "occurred_on" => "2027-05-12",
            "refund_method" => "hotel_credit"
          })
        )

      assert accepted["status"] == "applied"
      assert accepted["credit_issued_cents"] == CreditsBonus.expected(100)

      {conn, _} =
        one(
          conn,
          open_op("new-window", %{"occurred_on" => "2027-01-02", "arrival_on" => "2027-06-01"})
        )

      {conn, _} = one(conn, payment_op("new-window", 100))

      {conn, rejected} =
        one(
          conn,
          cancel_op("new-window", %{
            "occurred_on" => "2027-05-12",
            "refund_method" => "hotel_credit"
          })
        )

      assert rejected["code"] == "refund_method_not_available"
      assert group(conn, "new-window")["status"] == "active"
      assert group(conn, "new-window")["revision"] == 2
    end

    test "restoring one group leaves credit applied to another group on the same lot", %{
      conn: conn
    } do
      conn = issue(conn, "shared", "guest-22", 200)
      issued = CreditsBonus.expected(200)

      {conn, _} = one(conn, open_op("hold-a", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, credit_op("hold-a", 80))
      {conn, _} = one(conn, open_op("hold-b", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, credit_op("hold-b", 50))

      assert credit(conn, "guest-22")["available_cents"] == issued - 130
      assert ledger(conn)["data"]["credit_liability_cents"] == issued

      {conn, result} =
        one(
          conn,
          cancel_op("hold-a", %{"occurred_on" => "2026-11-20", "refund_method" => "cash"})
        )

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert credit(conn, "guest-22")["available_cents"] == issued - 50
      assert group(conn, "hold-b")["credit_paid_cents"] == 50
      assert group(conn, "hold-b")["status"] == "active"
      assert ledger(conn)["data"]["credit_liability_cents"] == issued
    end

    test "a refundable hotel-credit cancellation with no cash issues nothing", %{conn: conn} do
      {conn, _} = one(conn, open_op("empty", %{"guest_id" => "nobody"}))

      {conn, result} =
        one(
          conn,
          cancel_op("empty", %{"occurred_on" => "2026-11-01", "refund_method" => "hotel_credit"})
        )

      assert result["credit_issued_cents"] == 0
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["status"] == "applied"
      assert credit(conn, "nobody")["lots"] == []
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 0
    end

    test "converted cash accumulates and does not count as refunded or retained", %{conn: conn} do
      {conn, _} = one(conn, open_op("a", %{"guest_id" => "pool"}))
      {conn, _} = one(conn, payment_op("a", 100))
      {conn, _} = one(conn, cancel_op("a", %{"refund_method" => "hotel_credit"}))

      {conn, _} = one(conn, open_op("b", %{"guest_id" => "pool"}))
      {conn, _} = one(conn, payment_op("b", 250))
      {conn, _} = one(conn, cancel_op("b", %{"refund_method" => "hotel_credit"}))

      {conn, _} = one(conn, open_op("held", %{"guest_id" => "other"}))
      {conn, _} = one(conn, payment_op("held", 40))

      data = ledger(conn)["data"]
      assert data["cash_held_cents"] == 40
      assert data["cash_converted_to_credit_cents"] == 350
      assert data["cash_refunded_cents"] == 0
      assert data["cash_retained_cents"] == 0

      assert data["credit_liability_cents"] ==
               CreditsBonus.expected(100) + CreditsBonus.expected(250)
    end
  end

  describe "applying credit" do
    test "redeems credit into the deposit without moving cash or liability", %{conn: conn} do
      conn = issue(conn, "src", "guest-22", 1000)

      {conn, _} = one(conn, open_op("next", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("next", 5000, %{"operation_id" => "cash"}))

      {conn, applied} =
        one(conn, credit_op("next", 400, %{"operation_id" => "use", "expected_revision" => 2}))

      assert applied == %{
               "operation_id" => "use",
               "status" => "applied",
               "group_id" => "next",
               "amount_cents" => 400,
               "outstanding_deposit_cents" => 14100,
               "revision" => 3
             }

      data = group(conn, "next")
      assert data["cash_paid_cents"] == 5000
      assert data["credit_paid_cents"] == 400
      assert data["deposit_paid_cents"] == 5400
      assert data["outstanding_deposit_cents"] == 19500 - 5400
      assert data["deposit_due_cents"] == 19500

      issued = CreditsBonus.expected(1000)
      assert credit(conn, "guest-22")["available_cents"] == issued - 400
      assert ledger(conn)["data"]["cash_held_cents"] == 5000
      assert ledger(conn)["data"]["credit_liability_cents"] == issued
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 1000
    end

    test "uses existing payment errors, then insufficient credit, without advancing revision", %{
      conn: conn
    } do
      conn = issue(conn, "src", "guest-22", 30)
      {conn, _} = one(conn, open_op("g", %{"guest_id" => "guest-22"}))
      before = snapshot(conn, "g")
      available = credit(conn, "guest-22")

      {conn, zero} = one(conn, credit_op("g", 0))
      {conn, negative} = one(conn, credit_op("g", -5, %{"operation_id" => "neg"}))

      {conn, text} =
        one(conn, credit_op("g", 1, %{"operation_id" => "text", "amount_cents" => "10"}))

      {conn, huge} = one(conn, credit_op("g", 19501, %{"operation_id" => "huge"}))

      missing =
        credit_op("g", 1, %{"operation_id" => "missing"})
        |> Map.delete("amount_cents")

      {conn, missing_amount} = one(conn, missing)
      {conn, short} = one(conn, credit_op("g", 40, %{"operation_id" => "short"}))
      {conn, gone} = one(conn, credit_op("missing", 1))

      assert zero["code"] == "invalid_amount"
      assert negative["code"] == "invalid_amount"
      assert text["code"] == "invalid_amount"
      assert huge["code"] == "payment_exceeds_outstanding"
      assert missing_amount["code"] == "invalid_operation"
      assert short["code"] == "insufficient_credit"
      assert gone["code"] == "group_not_found"
      assert snapshot(conn, "g") == before
      assert credit(conn, "guest-22") == available

      {conn, _} = one(conn, cancel_op("g"))

      {conn, inactive} =
        one(conn, credit_op("g", 1, %{"operation_id" => "late", "amount_cents" => -1}))

      assert inactive["code"] == "group_not_active"
      assert group(conn, "g")["revision"] == 2
    end

    test "checks outstanding before credit balance", %{conn: conn} do
      conn = issue(conn, "src", "guest-22", 100)

      {conn, _} =
        one(conn, open_op("small", %{"rooms" => one_room(10), "guest_id" => "guest-22"}))

      {conn, over} = one(conn, credit_op("small", 80))
      assert over["code"] == "payment_exceeds_outstanding"
      assert credit(conn, "guest-22")["available_cents"] == CreditsBonus.expected(100)
      assert group(conn, "small")["revision"] == 1
    end

    test "a stale revision is rejected before insufficient credit", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      {conn, _} = one(conn, payment_op("g", 10))
      before = snapshot(conn, "g")

      {_conn, stale} =
        one(conn, credit_op("g", 5, %{"operation_id" => "stale", "expected_revision" => 1}))

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
      assert snapshot(conn, "g") == before
    end

    test "consumes earliest expiry, then source operation id, across one revision", %{conn: conn} do
      conn = issue(conn, "z-late-id", "guest-22", 100, %{"occurred_on" => "2026-10-01"})
      conn = issue(conn, "a-early-id", "guest-22", 100, %{"occurred_on" => "2026-11-01"})

      {conn, _} = one(conn, open_op("buyer", %{"guest_id" => "guest-22"}))

      {conn, applied} = one(conn, credit_op("buyer", 150, %{"operation_id" => "span"}))
      assert applied["status"] == "applied"
      assert applied["revision"] == 2

      assert credit(conn, "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "a-early-id",
                 "remaining_cents" => CreditsBonus.expected(100) - 40,
                 "expires_on" => "2027-11-02"
               }
             ]

      conn =
        issue(conn, "m-2", "tie-guest", 100, %{"occurred_on" => "2026-12-01", "group_id" => "s2"})

      conn =
        issue(conn, "m-10", "tie-guest", 100, %{
          "occurred_on" => "2026-12-01",
          "group_id" => "s10"
        })

      {conn, _} = one(conn, open_op("buyer-2", %{"guest_id" => "tie-guest"}))
      {conn, tied} = one(conn, credit_op("buyer-2", 50))
      assert tied["revision"] == 2

      same_day = credit(conn, "tie-guest")["lots"]

      assert Enum.map(same_day, & &1["source_operation_id"]) == ["m-10", "m-2"]

      m10 = Enum.find(same_day, &(&1["source_operation_id"] == "m-10"))
      m2 = Enum.find(same_day, &(&1["source_operation_id"] == "m-2"))
      assert m10["remaining_cents"] == CreditsBonus.expected(100) - 50
      assert m2["remaining_cents"] == CreditsBonus.expected(100)
    end

    test "credit is isolated to the group's guest and evaluated on occurred_on", %{conn: conn} do
      conn = issue(conn, "cancel-17", "guest-22", 5000, %{"occurred_on" => "2026-11-01"})
      {conn, _} = one(conn, open_op("other", %{"guest_id" => "guest-99"}))

      {conn, foreign} = one(conn, credit_op("other", 100, %{"occurred_on" => "2026-12-01"}))
      assert foreign["code"] == "insufficient_credit"

      {conn, _} = one(conn, open_op("own", %{"guest_id" => "guest-22"}))

      {conn, expired} =
        one(
          conn,
          credit_op("own", 100, %{"occurred_on" => "2027-11-02", "operation_id" => "late"})
        )

      assert expired["code"] == "insufficient_credit"
      assert group(conn, "own")["revision"] == 1

      {conn, in_window} =
        one(conn, credit_op("own", 100, %{"occurred_on" => "2027-11-01", "operation_id" => "ok"}))

      assert in_window["status"] == "applied"
      assert credit(conn, "guest-22", "2027-11-01")["available_cents"] == 5400
      assert credit(conn, "guest-99")["available_cents"] == 0
    end

    test "later batch operations see credit issued earlier in the batch", %{conn: conn} do
      {conn, results} =
        batch(conn, [
          open_op("first", %{"guest_id" => "guest-22"}),
          payment_op("first", 200),
          cancel_op("first", %{"refund_method" => "hotel_credit", "operation_id" => "Cancel/17"}),
          open_op("second", %{"guest_id" => "guest-22", "operation_id" => "open-2"}),
          credit_op("second", 50, %{"operation_id" => "apply", "expected_revision" => 1})
        ])

      assert Enum.map(results, & &1["status"]) == [
               "applied",
               "applied",
               "applied",
               "applied",
               "applied"
             ]

      assert Enum.at(results, 2)["credit_issued_cents"] == CreditsBonus.expected(200)

      assert credit(conn, "guest-22")["lots"] |> hd() |> Map.get("source_operation_id") ==
               "Cancel/17"

      assert group(conn, "second")["credit_paid_cents"] == 50
      assert group(conn, "second")["revision"] == 2
    end
  end

  describe "settling credit-funded groups" do
    test "refundable cash cancellation restores original lots without a second bonus", %{
      conn: conn
    } do
      conn = issue(conn, "cancel-17", "guest-22", 1000)
      issued = CreditsBonus.expected(1000)

      {conn, _} = one(conn, open_op("next", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("next", 500))
      {conn, _} = one(conn, credit_op("next", issued))

      {conn, result} =
        one(conn, cancel_op("next", %{"occurred_on" => "2026-11-20", "refund_method" => "cash"}))

      assert result["refunded_cents"] == 500
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 4

      assert credit(conn, "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => issued,
                 "expires_on" => "2027-11-02"
               }
             ]

      data = ledger(conn)["data"]
      assert data["cash_refunded_cents"] == 500
      assert data["cash_held_cents"] == 0
      assert data["credit_liability_cents"] == issued
    end

    test "refundable hotel credit bonuses only the new cash and restores prior lots", %{
      conn: conn
    } do
      conn = issue(conn, "original", "guest-22", 100, %{"occurred_on" => "2026-10-01"})
      original = CreditsBonus.expected(100)

      {conn, _} = one(conn, open_op("next", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("next", 50))
      {conn, _} = one(conn, credit_op("next", original))

      {conn, result} =
        one(
          conn,
          cancel_op("next", %{
            "operation_id" => "second-cancel",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == CreditsBonus.expected(50)

      lots = credit(conn, "guest-22")["lots"]

      assert lots == [
               %{
                 "source_operation_id" => "original",
                 "remaining_cents" => original,
                 "expires_on" => "2027-10-02"
               },
               %{
                 "source_operation_id" => "second-cancel",
                 "remaining_cents" => CreditsBonus.expected(50),
                 "expires_on" => "2027-11-21"
               }
             ]

      data = ledger(conn)["data"]
      assert data["cash_converted_to_credit_cents"] == 150
      assert data["cash_refunded_cents"] == 0
      assert data["cash_retained_cents"] == 0
      assert data["credit_liability_cents"] == original + CreditsBonus.expected(50)
    end

    test "non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      conn = issue(conn, "original", "guest-22", 100)
      original = CreditsBonus.expected(100)

      {conn, _} = one(conn, open_op("keep", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, credit_op("keep", 40))

      {conn, _} = one(conn, open_op("lose", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, payment_op("lose", 80))
      {conn, _} = one(conn, credit_op("lose", 60))

      before_liability = ledger(conn)["data"]["credit_liability_cents"]
      assert before_liability == original

      {conn, result} = one(conn, cancel_op("lose", %{"occurred_on" => "2026-12-09"}))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 80
      assert result["credit_issued_cents"] == 0

      lots = credit(conn, "guest-22")["lots"]

      assert lots == [
               %{
                 "source_operation_id" => "original",
                 "remaining_cents" => original - 100,
                 "expires_on" => "2027-11-02"
               }
             ]

      data = ledger(conn)["data"]
      assert data["cash_retained_cents"] == 80
      assert data["cash_held_cents"] == 0
      assert data["credit_liability_cents"] == original - 60

      {conn, blocked} =
        one(
          conn,
          cancel_op("lose", %{"operation_id" => "again", "refund_method" => "hotel_credit"})
        )

      assert blocked["code"] == "group_not_active"
      assert group(conn, "keep")["credit_paid_cents"] == 40
    end

    test "restored credit that has already expired does not become available", %{conn: conn} do
      conn =
        issue(conn, "aging", "guest-22", 200, %{
          "occurred_on" => "2026-11-01",
          "arrival_on" => "2027-06-01"
        })

      issued = CreditsBonus.expected(200)

      {conn, _} =
        one(
          conn,
          open_op("funded", %{
            "guest_id" => "guest-22",
            "occurred_on" => "2026-10-03",
            "arrival_on" => "2027-11-16",
            "departure_on" => "2027-11-18"
          })
        )

      {conn, _} = one(conn, credit_op("funded", issued, %{"occurred_on" => "2026-12-01"}))
      assert credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn, "2027-11-02")["data"]["credit_liability_cents"] == issued

      {conn, expired_restore} =
        one(
          conn,
          cancel_op("funded", %{
            "occurred_on" => "2027-11-02",
            "refund_method" => "cash"
          })
        )

      assert expired_restore["status"] == "applied"
      assert expired_restore["credit_issued_cents"] == 0
      assert credit(conn, "guest-22", "2027-11-01")["lots"] == []
      assert credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["data"]["credit_liability_cents"] == 0

      conn =
        issue(conn, "still-good", "guest-22", 80, %{
          "occurred_on" => "2026-11-01",
          "group_id" => "source-2",
          "arrival_on" => "2027-06-01"
        })

      still = CreditsBonus.expected(80)

      {conn, _} =
        one(
          conn,
          open_op("funded-2", %{
            "guest_id" => "guest-22",
            "arrival_on" => "2027-11-16",
            "departure_on" => "2027-11-18"
          })
        )

      {conn, _} = one(conn, credit_op("funded-2", still, %{"occurred_on" => "2027-01-04"}))

      {conn, restored} =
        one(
          conn,
          cancel_op("funded-2", %{"occurred_on" => "2027-11-01", "refund_method" => "cash"})
        )

      assert restored["status"] == "applied"

      assert credit(conn, "guest-22", "2027-11-01")["lots"] == [
               %{
                 "source_operation_id" => "still-good",
                 "remaining_cents" => still,
                 "expires_on" => "2027-11-02"
               }
             ]

      assert ledger(conn, "2027-11-01")["data"]["credit_liability_cents"] == still
      assert ledger(conn, "2027-11-02")["data"]["credit_liability_cents"] == 0
    end

    test "expiry is paused while credit funds an active group", %{conn: conn} do
      conn = issue(conn, "paused", "guest-22", 100, %{"occurred_on" => "2026-11-01"})
      issued = CreditsBonus.expected(100)

      {conn, _} = one(conn, open_op("hold", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, credit_op("hold", 40, %{"occurred_on" => "2026-12-01"}))

      assert credit(conn, "guest-22", "2027-11-01")["available_cents"] == issued - 40
      assert credit(conn, "guest-22", "2027-11-02")["lots"] == []
      assert ledger(conn, "2027-11-01")["data"]["credit_liability_cents"] == issued
      assert ledger(conn, "2027-11-02")["data"]["credit_liability_cents"] == 40
      assert ledger(conn, "2027-11-02")["data"]["cash_held_cents"] == 0
      assert ledger(conn, "2026-01-01")["data"]["cash_converted_to_credit_cents"] == 100
    end

    test "advance-purchase deposits can be funded by credit and then consume it", %{conn: conn} do
      conn = issue(conn, "wallet", "guest-22", 300)

      {conn, _} =
        one(
          conn,
          open_op("ap", %{
            "guest_id" => "guest-22",
            "rate_plan" => "advance_purchase",
            "rooms" => one_room(1000)
          })
        )

      {conn, applied} = one(conn, credit_op("ap", 200))
      assert applied["outstanding_deposit_cents"] == 2800
      assert group(conn, "ap")["credit_paid_cents"] == 200
      assert group(conn, "ap")["policy_version"] == "advance-nonrefundable"

      {conn, result} = one(conn, cancel_op("ap", %{"occurred_on" => "2026-10-04"}))
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert credit(conn, "guest-22")["available_cents"] == CreditsBonus.expected(300) - 200
      assert ledger(conn)["data"]["credit_liability_cents"] == CreditsBonus.expected(300) - 200
    end
  end

  describe "credit and ledger reads" do
    test "unknown guests have no credit and expired or exhausted lots are omitted", %{conn: conn} do
      assert credit(conn, "missing-guest") == %{
               "guest_id" => "missing-guest",
               "available_cents" => 0,
               "lots" => []
             }

      conn = issue(conn, "gone", "guest-22", 100)
      {conn, _} = one(conn, open_op("use", %{"guest_id" => "guest-22"}))
      {conn, _} = one(conn, credit_op("use", CreditsBonus.expected(100)))
      assert credit(conn, "guest-22")["lots"] == []
    end

    test "invalid on dates are rejected and a missing on uses the current UTC date", %{conn: conn} do
      assert invalid_on(conn, "/api/v1/ledger?on=2026-13-40") == %{
               "error" => %{"code" => "invalid_date"}
             }

      assert invalid_on(conn, "/api/v1/guests/guest-22/credit?on=yesterday") == %{
               "error" => %{"code" => "invalid_date"}
             }

      today = Date.utc_today()
      cancel_on = Date.add(today, -366)
      arrival = Date.add(cancel_on, 20)

      {conn, _} =
        one(
          conn,
          open_op("aged", %{
            "guest_id" => "aged-guest",
            "occurred_on" => Date.to_iso8601(Date.add(cancel_on, -1)),
            "arrival_on" => Date.to_iso8601(arrival),
            "departure_on" => Date.to_iso8601(Date.add(arrival, 2))
          })
        )

      {conn, _} =
        one(conn, payment_op("aged", 100, %{"occurred_on" => Date.to_iso8601(cancel_on)}))

      {conn, result} =
        one(
          conn,
          cancel_op("aged", %{
            "occurred_on" => Date.to_iso8601(cancel_on),
            "refund_method" => "hotel_credit"
          })
        )

      expires_on = Date.add(cancel_on, 366)
      assert expires_on == today
      assert result["credit_issued_cents"] == CreditsBonus.expected(100)
      assert credit(conn, "aged-guest")["lots"] == []
      assert ledger(conn)["data"]["credit_liability_cents"] == 0

      yesterday = Date.add(today, -1) |> Date.to_iso8601()

      assert credit(conn, "aged-guest", yesterday)["available_cents"] ==
               CreditsBonus.expected(100)

      assert ledger(conn, yesterday)["data"]["credit_liability_cents"] ==
               CreditsBonus.expected(100)
    end
  end

  defp issue(conn, operation_id, guest_id, cash, overrides \\ %{}) do
    group_id = overrides["group_id"] || "src-#{operation_id}"
    occurred_on = overrides["occurred_on"] || "2026-11-01"
    arrival = overrides["arrival_on"] || "2026-12-20"

    {conn, opened} =
      one(
        conn,
        open_op(group_id, %{
          "operation_id" => "open-#{operation_id}",
          "guest_id" => guest_id,
          "occurred_on" => "2026-09-01",
          "arrival_on" => arrival,
          "departure_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(arrival), 1)),
          "rooms" => one_room(cash * 5)
        })
      )

    assert opened["status"] == "applied"
    assert opened["deposit_due_cents"] >= cash

    {conn, _} =
      one(
        conn,
        payment_op(group_id, cash, %{
          "operation_id" => "pay-#{operation_id}",
          "occurred_on" => occurred_on
        })
      )

    {conn, cancelled} =
      one(
        conn,
        cancel_op(group_id, %{
          "operation_id" => operation_id,
          "occurred_on" => occurred_on,
          "refund_method" => "hotel_credit"
        })
      )

    assert cancelled["status"] == "applied", inspect(cancelled)
    assert cancelled["credit_issued_cents"] == CreditsBonus.expected(cash)
    conn
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

  defp invalid_on(conn, path) do
    conn
    |> get(path)
    |> json_response(422)
  end

  defp snapshot(conn, group_id) do
    data = group(conn, group_id)

    %{
      revision: data["revision"],
      paid: data["deposit_paid_cents"],
      cash: data["cash_paid_cents"],
      credit: data["credit_paid_cents"],
      arrival: data["arrival_on"],
      status: data["status"],
      ledger: ledger(conn)["data"],
      credit_balance: credit(conn, data["guest_id"])
    }
  end

  defp open_op(group_id, overrides \\ %{}) do
    merged =
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
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        },
        overrides
      )

    if Map.has_key?(overrides, "arrival_on") and not Map.has_key?(overrides, "departure_on") do
      arrival = Date.from_iso8601!(merged["arrival_on"])
      Map.put(merged, "departure_on", Date.to_iso8601(Date.add(arrival, 3)))
    else
      merged
    end
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

  defp credit_op(group_id, amount, overrides \\ %{}) do
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

  defp reschedule_op(group_id, new_arrival, overrides) do
    Map.merge(
      %{
        "operation_id" => "move-#{group_id}",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides \\ %{}) do
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

  defp one_room(rate), do: [%{"room_id" => "room-a", "nightly_rate_cents" => rate}]
end

defmodule CreditsBonus do
  def expected(cash), do: GroupStay.Credits.issued_amount(cash)
end
