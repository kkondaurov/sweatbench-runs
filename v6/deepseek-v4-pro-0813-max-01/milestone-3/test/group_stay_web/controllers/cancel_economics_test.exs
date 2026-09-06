defmodule GroupStayWeb.CancelEconomicsTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, op) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => [op]})
    Jason.decode!(resp.resp_body)["results"] |> hd()
  end

  defp departure_on(arrival_on) do
    arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601()
  end

  defp open(conn, group_id, opts) do
    arrival_on = Keyword.get(opts, :arrival_on, "2026-12-10")

    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :booked_on, "2026-10-03"),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => departure_on(arrival_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    })
  end

  defp pay(conn, group_id, amount_cents, opts \\ []) do
    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "pay-#{group_id}"),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-04"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp cancel(conn, group_id, occurred_on, opts \\ []) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    op =
      case Keyword.fetch(opts, :refund_method) do
        {:ok, method} -> Map.put(op, "refund_method", method)
        :error -> op
      end

    submit(conn, op)
  end

  defp apply_credit(conn, group_id, amount_cents, occurred_on, opts \\ []) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "credit-#{group_id}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }

    op =
      case Keyword.fetch(opts, :expected_revision) do
        {:ok, revision} -> Map.put(op, "expected_revision", revision)
        :error -> op
      end

    submit(conn, op)
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn, query \\ "") do
    conn |> get("/api/v1/ledger#{query}") |> json_response(200) |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, query \\ "") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "policy versions" do
    test "flex-30 applies to flexible groups booked on or after 2027-01-01", %{conn: conn} do
      open(conn, "group-flex30", booked_on: "2027-01-01", arrival_on: "2027-03-31")

      data = group(conn, "group-flex30")
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-03-01"

      pay(conn, "group-flex30", 3_000)

      # Cancellation exactly 30 days before arrival is refundable.
      assert cancel(conn, "group-flex30", "2027-03-01") == %{
               "operation_id" => "cancel-group-flex30",
               "status" => "applied",
               "group_id" => "group-flex30",
               "refunded_cents" => 3_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "flex-30 is not refundable within 30 days; flex-14 keeps its window", %{conn: conn} do
      open(conn, "group-flex30", booked_on: "2027-01-01", arrival_on: "2027-03-31")
      pay(conn, "group-flex30", 1_000)

      # 29 days before arrival is inside the 30-day window.
      result = cancel(conn, "group-flex30", "2027-03-02")
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1_000

      open(conn, "group-flex14", booked_on: "2026-12-31", arrival_on: "2027-06-30")
      pay(conn, "group-flex14", 700)

      assert group(conn, "group-flex14")["policy_version"] == "flex-14"
      assert group(conn, "group-flex14")["refundable_until"] == "2027-06-16"

      # Exactly 14 days before arrival is refundable.
      result = cancel(conn, "group-flex14", "2027-06-16")
      assert result["refunded_cents"] == 700
      assert result["retained_cents"] == 0
    end

    test "advance purchase stays non-refundable with a null refundable_until", %{conn: conn} do
      open(conn, "group-advance",
        rate_plan: "advance_purchase",
        booked_on: "2027-05-01",
        arrival_on: "2027-08-01"
      )

      data = group(conn, "group-advance")
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil

      pay(conn, "group-advance", 10_000)

      result = cancel(conn, "group-advance", "2027-06-01")
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      open(conn, "group-move", booked_on: "2026-12-31", arrival_on: "2027-06-30")

      result =
        submit(conn, %{
          "operation_id" => "mov-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-move",
          "new_arrival_on" => "2027-08-04"
        })

      assert result == %{
               "operation_id" => "mov-1",
               "status" => "applied",
               "group_id" => "group-move",
               "new_arrival_on" => "2027-08-04",
               "new_departure_on" => "2027-08-07",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-07-21",
               "revision" => 2
             }

      data = group(conn, "group-move")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-07-21"
    end
  end

  describe "issuing credit on cancellation" do
    test "hotel credit converts refundable cash into a 110% lot", %{conn: conn} do
      open(conn, "group-credit", booked_on: "2027-01-01", arrival_on: "2027-03-31")
      pay(conn, "group-credit", 6_000)

      result = cancel(conn, "group-credit", "2027-03-01", refund_method: "hotel_credit")

      assert result == %{
               "operation_id" => "cancel-group-credit",
               "status" => "applied",
               "group_id" => "group-credit",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 6_600,
               "revision" => 3
             }

      assert ledger(conn, "?on=2027-03-02") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 6_000,
               "credit_liability_cents" => 6_600
             }

      # The lot is available through 365 days after cancellation and expires
      # the following day.
      assert credit(conn, "guest-22", "?on=2027-03-02") == %{
               "guest_id" => "guest-22",
               "available_cents" => 6_600,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-credit",
                   "remaining_cents" => 6_600,
                   "expires_on" => "2028-03-01"
                 }
               ]
             }
    end

    test "the 10% bonus uses the standard rounding rule", %{conn: conn} do
      open(conn, "group-round", booked_on: "2027-01-01", arrival_on: "2027-03-31")
      pay(conn, "group-round", 2_555)

      result = cancel(conn, "group-round", "2027-03-01", refund_method: "hotel_credit")

      # 10% of 2555 is 255.5; the exact half-cent rounds upward.
      assert result["credit_issued_cents"] == 2_811

      open(conn, "group-round2", booked_on: "2027-01-01", arrival_on: "2027-03-31")
      pay(conn, "group-round2", 51)

      result = cancel(conn, "group-round2", "2027-03-01", refund_method: "hotel_credit")

      # 10% of 51 is 5.1, which rounds down to 5.
      assert result["credit_issued_cents"] == 56
    end

    test "hotel credit is rejected for non-refundable cancellations", %{conn: conn} do
      open(conn, "group-late", booked_on: "2027-01-01", arrival_on: "2027-03-31")
      pay(conn, "group-late", 1_000)

      result = cancel(conn, "group-late", "2027-03-02", refund_method: "hotel_credit")

      assert result == %{
               "operation_id" => "cancel-group-late",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-late"
             }

      data = group(conn, "group-late")
      assert data["status"] == "active"
      assert data["revision"] == 2

      assert ledger(conn)["cash_held_cents"] == 1_000
      assert credit(conn, "guest-22")["lots"] == []
    end

    test "advance purchase also rejects hotel credit", %{conn: conn} do
      open(conn, "group-adv", rate_plan: "advance_purchase", arrival_on: "2027-08-01")
      pay(conn, "group-adv", 5_000)

      result = cancel(conn, "group-adv", "2027-06-01", refund_method: "hotel_credit")

      assert result["code"] == "refund_method_not_available"
      assert group(conn, "group-adv")["status"] == "active"
    end

    test "stale revisions are rejected before the refund method rules", %{conn: conn} do
      open(conn, "group-stale-refund", booked_on: "2027-01-01", arrival_on: "2027-03-31")
      pay(conn, "group-stale-refund", 1_000)

      # 29 days before arrival: the hotel credit refund would be rejected, but
      # the stale revision wins.
      result =
        submit(conn, %{
          "operation_id" => "cancel-stale",
          "type" => "cancel_group",
          "occurred_on" => "2027-03-02",
          "group_id" => "group-stale-refund",
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        })

      assert result == %{
               "operation_id" => "cancel-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-stale-refund",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert group(conn, "group-stale-refund")["revision"] == 2
    end

    test "unknown refund methods are invalid operations", %{conn: conn} do
      open(conn, "group-bad", booked_on: "2027-01-01", arrival_on: "2027-03-31")

      op = %{
        "operation_id" => "cancel-bad",
        "type" => "cancel_group",
        "occurred_on" => "2027-03-01",
        "group_id" => "group-bad",
        "refund_method" => "bitcoin"
      }

      assert submit(conn, op)["code"] == "invalid_operation"
    end
  end

  describe "apply_hotel_credit" do
    defp open_refunded_group(conn, group_id, guests) do
      open(conn, group_id,
        guest_id: guests[:guest_id],
        booked_on: guests[:booked_on],
        arrival_on: guests[:arrival_on]
      )

      pay(conn, group_id, guests[:pay], operation_id: "pay-#{group_id}-1")

      cancel(conn, group_id, guests[:cancel_on],
        refund_method: "hotel_credit",
        operation_id: guests[:cancel_id]
      )
    end

    test "funds an active group from unexpired credit without moving cash", %{conn: conn} do
      open_refunded_group(conn, "from-a",
        guest_id: "guest-credit",
        booked_on: "2026-10-03",
        arrival_on: "2026-12-10",
        pay: 1_000,
        cancel_on: "2026-11-01",
        cancel_id: "cancel-a"
      )

      assert ledger(conn, "?on=2026-12-01")["credit_liability_cents"] == 1_100

      open(conn, "group-to",
        guest_id: "guest-credit",
        booked_on: "2027-01-02",
        arrival_on: "2027-06-10"
      )

      result = apply_credit(conn, "group-to", 1_100, "2027-01-10")

      assert result == %{
               "operation_id" => "credit-group-to",
               "status" => "applied",
               "group_id" => "group-to",
               "amount_cents" => 1_100,
               "outstanding_deposit_cents" => 4_900,
               "revision" => 2
             }

      data = group(conn, "group-to")
      assert data["deposit_paid_cents"] == 1_100
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 1_100

      # Applying credit does not change the liability and never counts as cash.
      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_000,
               "credit_liability_cents" => 1_100
             }

      # The exhausted lot is omitted.
      assert credit(conn, "guest-credit", "?on=2027-01-11") == %{
               "guest_id" => "guest-credit",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "consumes lots by earliest expiry, then by source operation id", %{conn: conn} do
      guest_id = "guest-fifo"

      # Three lots for the same guest: two share the earliest expiry.
      open_refunded_group(conn, "src-a",
        guest_id: guest_id,
        booked_on: "2026-06-01",
        arrival_on: "2026-12-15",
        pay: 500,
        cancel_on: "2026-06-10",
        cancel_id: "cancel-a"
      )

      open_refunded_group(conn, "src-z",
        guest_id: guest_id,
        booked_on: "2026-06-05",
        arrival_on: "2026-12-20",
        pay: 550,
        cancel_on: "2026-06-10",
        cancel_id: "cancel-z"
      )

      open_refunded_group(conn, "src-b",
        guest_id: guest_id,
        booked_on: "2026-07-01",
        arrival_on: "2027-01-15",
        pay: 2_000,
        cancel_on: "2026-07-05",
        cancel_id: "cancel-b"
      )

      open(conn, "group-fifo",
        guest_id: guest_id,
        booked_on: "2027-02-01",
        arrival_on: "2027-12-20"
      )

      # 550 (cancel-a) + 605 (cancel-z) are taken before cancel-b's lot.
      assert apply_credit(conn, "group-fifo", 1_155, "2027-02-10")["status"] == "applied"

      assert credit(conn, guest_id, "?on=2027-06-10") == %{
               "guest_id" => guest_id,
               "available_cents" => 2_200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 2_200,
                   "expires_on" => "2027-07-06"
                 }
               ]
             }

      assert apply_credit(conn, "group-fifo", 500, "2027-03-01",
               operation_id: "credit-group-fifo-2"
             )["status"] == "applied"

      # A refundable cancellation restores each portion to its original lot.
      data = group(conn, "group-fifo")
      assert data["credit_paid_cents"] == 1_655
      assert data["cash_paid_cents"] == 0

      result = cancel(conn, "group-fifo", "2027-06-01")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert credit(conn, guest_id, "?on=2027-06-10") == %{
               "guest_id" => guest_id,
               "available_cents" => 3_355,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-a",
                   "remaining_cents" => 550,
                   "expires_on" => "2027-06-11"
                 },
                 %{
                   "source_operation_id" => "cancel-z",
                   "remaining_cents" => 605,
                   "expires_on" => "2027-06-11"
                 },
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 2_200,
                   "expires_on" => "2027-07-06"
                 }
               ]
             }

      assert ledger(conn, "?on=2027-06-05")["credit_liability_cents"] == 3_355
    end

    test "rejects unusable amounts, missing credit, and inactive groups", %{conn: conn} do
      open(conn, "group-x", guest_id: "guest-none", arrival_on: "2027-06-10")

      assert apply_credit(conn, "group-x", 0, "2027-01-10", operation_id: "credit-x-zero")[
               "code"
             ] == "invalid_amount"

      assert apply_credit(conn, "group-x", -5, "2027-01-10", operation_id: "credit-x-neg")[
               "code"
             ] == "invalid_amount"

      assert apply_credit(conn, "group-x", 100.5, "2027-01-10", operation_id: "credit-x-float")[
               "code"
             ] == "invalid_amount"

      assert apply_credit(conn, "group-x", 9_999_999, "2027-01-10", operation_id: "credit-x-big")[
               "code"
             ] == "payment_exceeds_outstanding"

      assert apply_credit(conn, "group-x", 500, "2027-01-10", operation_id: "credit-x-none")[
               "code"
             ] == "insufficient_credit"

      assert apply_credit(conn, "group-missing", 500, "2027-01-10")["code"] == "group_not_found"

      missing_amount =
        submit(conn, %{
          "operation_id" => "credit-missing-amount",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-10",
          "group_id" => "group-x"
        })

      assert missing_amount["code"] == "invalid_operation"

      missing_date =
        submit(conn, %{
          "operation_id" => "credit-missing-date",
          "type" => "apply_hotel_credit",
          "group_id" => "group-x",
          "amount_cents" => 500
        })

      assert missing_date["code"] == "invalid_operation"

      assert group(conn, "group-x")["revision"] == 1
    end

    test "rejects later operations addressed to cancelled groups", %{conn: conn} do
      open(conn, "group-x2", guest_id: "guest-none", arrival_on: "2027-06-10")
      cancel(conn, "group-x2", "2027-04-01")

      assert apply_credit(conn, "group-x2", 500, "2027-01-10")["code"] == "group_not_active"
    end

    test "stale revisions win over credit domain rules", %{conn: conn} do
      open(conn, "group-stale", guest_id: "guest-none", arrival_on: "2027-06-10")

      result = apply_credit(conn, "group-stale", 500, "2027-01-10", expected_revision: 9)

      assert result == %{
               "operation_id" => "credit-group-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-stale",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
    end

    test "a matching expected revision applies and is checked before the credit rules", %{
      conn: conn
    } do
      open(conn, "group-ok", guest_id: "guest-none", arrival_on: "2027-06-10")

      result = apply_credit(conn, "group-ok", 500, "2027-01-10", expected_revision: 1)

      assert result["code"] == "insufficient_credit"

      assert group(conn, "group-ok")["revision"] == 1
    end

    test "expiry is evaluated using the operation's occurred_on date", %{conn: conn} do
      guest_id = "guest-expiry"

      open_refunded_group(conn, "src-e",
        guest_id: guest_id,
        booked_on: "2026-06-01",
        arrival_on: "2026-12-15",
        pay: 500,
        cancel_on: "2026-06-10",
        cancel_id: "cancel-e"
      )

      open(conn, "group-expiry", guest_id: guest_id, arrival_on: "2026-12-30")

      # The lot is available through 2027-06-10 and expires on 2027-06-11.
      assert apply_credit(conn, "group-expiry", 100, "2027-06-10")["status"] == "applied"

      assert apply_credit(conn, "group-expiry", 100, "2027-06-11",
               operation_id: "credit-group-expiry-2"
             )["code"] == "insufficient_credit"

      assert group(conn, "group-expiry")["revision"] == 2
    end
  end

  describe "settling groups funded by credit" do
    test "cash is refunded and applied credit returns without a second bonus", %{conn: conn} do
      guest_id = "guest-settle"

      open_refunded_group(conn, "src-s",
        guest_id: guest_id,
        booked_on: "2026-10-03",
        arrival_on: "2026-12-10",
        pay: 1_000,
        cancel_on: "2026-11-01",
        cancel_id: "cancel-s"
      )

      open(conn, "group-mix",
        guest_id: guest_id,
        booked_on: "2027-01-01",
        arrival_on: "2027-03-31"
      )

      pay(conn, "group-mix", 500, operation_id: "pay-mix")
      apply_credit(conn, "group-mix", 500, "2027-01-10")

      result = cancel(conn, "group-mix", "2027-03-01")

      # Only the cash portion is refunded; the credit portion is restored.
      assert result["refunded_cents"] == 500
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert credit(conn, guest_id, "?on=2027-03-01") == %{
               "guest_id" => guest_id,
               "available_cents" => 1_100,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-s",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger(conn, "?on=2027-03-01") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 500,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_000,
               "credit_liability_cents" => 1_100
             }
    end

    test "hotel credit refunds convert cash and restore applied credit without bonus", %{
      conn: conn
    } do
      guest_id = "guest-double"

      open_refunded_group(conn, "src-d",
        guest_id: guest_id,
        booked_on: "2026-10-03",
        arrival_on: "2026-12-10",
        pay: 1_000,
        cancel_on: "2026-11-01",
        cancel_id: "cancel-d"
      )

      open(conn, "group-double",
        guest_id: guest_id,
        booked_on: "2027-01-01",
        arrival_on: "2027-03-31"
      )

      pay(conn, "group-double", 1_000, operation_id: "pay-double")
      apply_credit(conn, "group-double", 500, "2027-01-10")

      result = cancel(conn, "group-double", "2027-03-01", refund_method: "hotel_credit")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 1_100

      # The converted lot (2028-03-01) and the restored lot (2027-11-02) both
      # exist; the restored lot receives no second 10% bonus.
      assert credit(conn, guest_id, "?on=2027-03-01") == %{
               "guest_id" => guest_id,
               "available_cents" => 2_200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-d",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2027-11-02"
                 },
                 %{
                   "source_operation_id" => "cancel-group-double",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-03-01"
                 }
               ]
             }

      assert ledger(conn)["cash_converted_to_credit_cents"] == 2_000
      assert ledger(conn, "?on=2027-03-01")["credit_liability_cents"] == 2_200
    end

    test "non-refundable cancellations consume applied credit", %{conn: conn} do
      guest_id = "guest-consumed"

      open_refunded_group(conn, "src-c",
        guest_id: guest_id,
        booked_on: "2026-10-03",
        arrival_on: "2026-12-10",
        pay: 1_000,
        cancel_on: "2026-11-01",
        cancel_id: "cancel-c"
      )

      open(conn, "group-late", guest_id: guest_id, arrival_on: "2026-12-10")
      apply_credit(conn, "group-late", 1_100, "2026-11-20")

      assert ledger(conn)["credit_liability_cents"] == 1_100

      # 13 days before arrival is non-refundable.
      result = cancel(conn, "group-late", "2026-11-27")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      # Applied credit is consumed rather than returned.
      assert credit(conn, guest_id)["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "restored credit whose lot already expired reduces the liability", %{conn: conn} do
      guest_id = "guest-expired"

      open_refunded_group(conn, "src-x",
        guest_id: guest_id,
        booked_on: "2026-06-01",
        arrival_on: "2026-12-15",
        pay: 1_000,
        cancel_on: "2026-06-01",
        cancel_id: "cancel-x"
      )

      open(conn, "group-expired",
        guest_id: guest_id,
        booked_on: "2027-01-01",
        arrival_on: "2027-08-01"
      )

      apply_credit(conn, "group-expired", 1_100, "2027-01-10")
      assert ledger(conn)["credit_liability_cents"] == 1_100

      # Cancellation happens on the lot's expiry day: the restored amount
      # expires immediately instead of becoming available again.
      result = cancel(conn, "group-expired", "2027-06-02")
      assert result["status"] == "applied"

      assert credit(conn, guest_id)["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end
  end

  describe "credit and ledger reads with a date" do
    test "the ledger reports credit liability as of the requested date", %{conn: conn} do
      open_refunded_group(conn, "src-date",
        guest_id: "guest-date",
        booked_on: "2026-06-01",
        arrival_on: "2026-12-15",
        pay: 1_000,
        cancel_on: "2026-06-10",
        cancel_id: "cancel-date"
      )

      assert ledger(conn, "?on=2027-06-10")["credit_liability_cents"] == 1_100
      assert ledger(conn, "?on=2027-06-11")["credit_liability_cents"] == 0
    end

    test "both reads reject unusable on dates", %{conn: conn} do
      assert get(conn, "/api/v1/ledger?on=not-a-date") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }

      assert get(conn, "/api/v1/guests/guest-22/credit?on=not-a-date") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}

      assert get(conn, "/api/v1/ledger?on=99") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end
end
