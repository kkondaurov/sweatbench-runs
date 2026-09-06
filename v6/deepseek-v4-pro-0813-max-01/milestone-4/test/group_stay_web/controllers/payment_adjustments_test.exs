defmodule GroupStayWeb.PaymentAdjustmentsTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, op) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => [op]})
    Jason.decode!(resp.resp_body)["results"] |> hd()
  end

  defp open(conn, group_id, opts \\ []) do
    arrival_on = Keyword.get(opts, :arrival_on, "2026-12-10")

    rooms =
      Keyword.get(
        opts,
        :rooms,
        for(id <- ~w(room-a room-b), do: %{"room_id" => id, "nightly_rate_cents" => 10_000})
      )

    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :booked_on, "2026-10-03"),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => rooms
    })
  end

  defp pay(conn, group_id, amount_cents, operation_id, opts \\ []) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-04"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp apply_credit(conn, group_id, amount_cents, occurred_on, operation_id) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp cancel_group(conn, group_id, occurred_on, operation_id, opts \\ []) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => Keyword.get(opts, :refund_method, "cash")
    })
  end

  defp reduce(conn, payment_operation_id, amount_cents, operation_id, opts \\ []) do
    op = %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }

    case Keyword.fetch(opts, :expected_revision) do
      {:ok, revision} -> submit(conn, Map.put(op, "expected_revision", revision))
      :error -> submit(conn, op)
    end
  end

  defp charge_back(conn, payment_operation_id, operation_id, opts \\ []) do
    op = %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id
    }

    case Keyword.fetch(opts, :expected_revision) do
      {:ok, revision} -> submit(conn, Map.put(op, "expected_revision", revision))
      :error -> submit(conn, op)
    end
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, payment_operation_id) do
    resp = get(conn, "/api/v1/payments/#{payment_operation_id}")
    {resp, Jason.decode!(resp.resp_body)}
  end

  describe "reduce_cash_payment" do
    test "removes held allocations in reverse fill order and reopens the deposit", %{conn: conn} do
      open(conn, "red-group")
      pay(conn, "red-group", 10_000, "red-pay")

      result = reduce(conn, "red-pay", 3_000, "red-1")

      assert result == %{
               "operation_id" => "red-1",
               "status" => "applied",
               "payment_operation_id" => "red-pay",
               "group_id" => "red-group",
               "amount_cents" => 3_000,
               "outstanding_deposit_cents" => 5_000,
               "revision" => 3
             }

      data = group(conn, "red-group")
      assert data["deposit_paid_cents"] == 7_000
      assert data["cash_paid_cents"] == 7_000
      assert data["outstanding_deposit_cents"] == 5_000

      rooms = Enum.map(data["rooms"], &{&1["room_id"], &1["cash_paid_cents"]})
      assert rooms == [{"room-a", 6_000}, {"room-b", 1_000}]

      assert ledger(conn)["cash_held_cents"] == 7_000
      assert ledger(conn)["cash_reduced_cents"] == 3_000

      {resp, body} = payment(conn, "red-pay")

      assert resp.status == 200

      assert body["data"] == %{
               "payment_operation_id" => "red-pay",
               "original_group_id" => "red-group",
               "recorded_cents" => 10_000,
               "held_cents" => 7_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3_000,
               "charged_back_cents" => 0
             }
    end

    test "successive reductions compose and removing the complete remainder is valid", %{
      conn: conn
    } do
      open(conn, "red-full")
      pay(conn, "red-full", 10_000, "red-full-pay")

      assert reduce(conn, "red-full-pay", 7_000, "red-full-1")["outstanding_deposit_cents"] ==
               9_000

      assert reduce(conn, "red-full-pay", 3_000, "red-full-2")["outstanding_deposit_cents"] ==
               12_000

      data = group(conn, "red-full")
      assert data["cash_paid_cents"] == 0
      assert ledger(conn)["cash_reduced_cents"] == 10_000
      assert ledger(conn)["cash_held_cents"] == 0

      assert reduce(conn, "red-full-pay", 1, "red-full-3")["code"] == "payment_not_reducible"
    end

    test "validates amounts and held cash", %{conn: conn} do
      open(conn, "red-valid")
      pay(conn, "red-valid", 10_000, "red-valid-pay")

      assert reduce(conn, "red-valid-pay", 0, "red-zero")["code"] == "invalid_amount"
      assert reduce(conn, "red-valid-pay", -5, "red-neg")["code"] == "invalid_amount"
      assert reduce(conn, "red-valid-pay", 100.5, "red-float")["code"] == "invalid_amount"

      assert submit(conn, %{
               "operation_id" => "red-missing",
               "type" => "reduce_cash_payment",
               "payment_operation_id" => "red-valid-pay"
             })["code"] == "invalid_operation"

      assert reduce(conn, "red-valid-pay", 10_001, "red-big")["code"] ==
               "reduction_exceeds_held_cash"

      assert group(conn, "red-valid")["revision"] == 2
      assert group(conn, "red-valid")["cash_paid_cents"] == 10_000
      assert ledger(conn)["cash_reduced_cents"] == 0

      # Removing the complete held portion succeeds...
      assert reduce(conn, "red-valid-pay", 10_000, "red-all-exact")["status"] == "applied"

      # ...but a payment with no held cash is not reducible.
      assert reduce(conn, "red-valid-pay", 1, "red-again")["code"] == "payment_not_reducible"
    end

    test "targeting, revisions, and operation records", %{conn: conn} do
      open(conn, "rev-group")
      pay(conn, "rev-group", 1_000, "rev-pay")

      # A missing durable record is operation_not_found.
      assert reduce(conn, "rev-ghost", 100, "rev-none")["code"] == "operation_not_found"

      # A stale revision is rejected against the original payment's group.
      assert reduce(conn, "rev-pay", 100, "rev-stale", expected_revision: 1) == %{
               "operation_id" => "rev-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "rev-group",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert group(conn, "rev-group")["revision"] == 2

      # A non-payment durable record is not reducible.
      assert reduce(conn, "open-rev-group", 100, "rev-open")["code"] == "payment_not_reducible"

      # A rejected payment record is not reducible.
      assert submit(conn, %{
               "operation_id" => "rev-rejected-pay",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "rev-group",
               "amount_cents" => 999_999
             })["code"] == "payment_exceeds_outstanding"

      assert reduce(conn, "rev-rejected-pay", 100, "rev-rej")["code"] == "payment_not_reducible"

      assert reduce(conn, "rev-pay", 500, "rev-ok")["revision"] == 3
      assert group(conn, "rev-group")["revision"] == 3
    end

    test "cash that has been settled is settled history", %{conn: conn} do
      open(conn, "settled-group")
      pay(conn, "settled-group", 2_000, "settled-pay")

      cancel_group(conn, "settled-group", "2026-11-01", "settled-cancel")

      assert ledger(conn)["cash_refunded_cents"] == 2_000

      assert reduce(conn, "settled-pay", 1, "settled-red")["code"] == "payment_not_reducible"

      # The original payment result is never rewritten.
      original =
        conn
        |> get("/api/v1/operations/settled-pay")
        |> json_response(200)
        |> Map.fetch!("data")

      assert original == %{
               "operation_id" => "settled-pay",
               "status" => "applied",
               "group_id" => "settled-group",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 10_000,
               "revision" => 2
             }

      {resp, body} = payment(conn, "settled-pay")
      assert resp.status == 200
      assert body["data"]["held_cents"] == 0
      assert body["data"]["refunded_cents"] == 2_000
    end

    test "is durably idempotent", %{conn: conn} do
      open(conn, "red-idem")
      pay(conn, "red-idem", 5_000, "red-idem-pay")

      op = %{
        "operation_id" => "red-idem-op",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "red-idem-pay",
        "amount_cents" => 2_000
      }

      first = submit(conn, op)
      assert first["status"] == "applied"

      assert submit(conn, op) == first
      assert group(conn, "red-idem")["revision"] == 3
      assert ledger(conn)["cash_reduced_cents"] == 2_000
    end
  end

  describe "charge_back_payment" do
    test "reclassifies refunded cash as charged back", %{conn: conn} do
      open(conn, "cbg-refund")
      pay(conn, "cbg-refund", 3_000, "cbg-refund-pay")
      cancel_group(conn, "cbg-refund", "2026-11-01", "cbg-refund-cancel")

      assert ledger(conn)["cash_refunded_cents"] == 3_000

      result = charge_back(conn, "cbg-refund-pay", "cbg-refund-op")

      assert result == %{
               "operation_id" => "cbg-refund-op",
               "status" => "applied",
               "payment_operation_id" => "cbg-refund-pay",
               "group_id" => "cbg-refund",
               "charged_back_cents" => 3_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 3_000
      assert group(conn, "cbg-refund")["revision"] == 4

      {resp, body} = payment(conn, "cbg-refund-pay")
      assert resp.status == 200

      assert body["data"] == %{
               "payment_operation_id" => "cbg-refund-pay",
               "original_group_id" => "cbg-refund",
               "recorded_cents" => 3_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 3_000
             }

      # The guest's historical refund is not reversed or reissued, and the
      # payment cannot be charged back again.
      assert charge_back(conn, "cbg-refund-pay", "cbg-refund-op-2")["code"] ==
               "payment_not_chargeable"
    end

    test "reverses held cash on active groups, reopening the outstanding deposit", %{conn: conn} do
      open(conn, "cbg-held")
      pay(conn, "cbg-held", 5_000, "cbg-held-pay")

      assert charge_back(conn, "cbg-held-pay", "cbg-held-stale", expected_revision: 1) == %{
               "operation_id" => "cbg-held-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "cbg-held",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      result = charge_back(conn, "cbg-held-pay", "cbg-held-op")

      assert result["charged_back_cents"] == 5_000
      assert result["outstanding_deposit_cents"] == 12_000
      assert result["revision"] == 3

      data = group(conn, "cbg-held")
      assert data["status"] == "active"
      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 12_000

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
    end

    test "revokes converted credit entitlement with telescoping bonuses and shortfalls", %{
      conn: conn
    } do
      guest_id = "guest-chargeback"

      open(conn, "cbg-src",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "cbg-src", 1_000, "cbg-src-p1")
      pay(conn, "cbg-src", 2_000, "cbg-src-p2")

      # Converted lot: 3000 cash -> 3300 credit.
      cancel_group(conn, "cbg-src", "2026-11-01", "cbg-src-cancel", refund_method: "hotel_credit")

      open(conn, "cbg-tgt",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      apply_credit(conn, "cbg-tgt", 3_000, "2026-11-10", "cbg-tgt-apply")

      assert ledger(conn)["credit_liability_cents"] == 3_300
      assert ledger(conn)["credit_shortfall_cents"] == 0

      # Charge back the first payment: entitlement is the bonus value of its
      # 1000 principal, 1100. The lot only has 300 remaining, so 800 is an
      # unrecovered clawback.
      result = charge_back(conn, "cbg-src-p1", "cbg-src-op1")

      assert result["charged_back_cents"] == 1_000
      assert ledger(conn)["cash_converted_to_credit_cents"] == 2_000
      assert ledger(conn)["credit_shortfall_cents"] == 800
      assert ledger(conn)["credit_liability_cents"] == 3_000

      # Only the original payment's group changed.
      assert group(conn, "cbg-src")["revision"] == 5
      assert group(conn, "cbg-tgt")["revision"] == 2

      # Charge back the second payment: entitlement is B(3000) - B(1000) =
      # 3300 - 1100 = 2200, none of which can come out of the empty lot.
      result = charge_back(conn, "cbg-src-p2", "cbg-src-op2")
      assert result["charged_back_cents"] == 2_000
      assert ledger(conn)["credit_shortfall_cents"] == 3_000
      assert ledger(conn)["cash_charged_back_cents"] == 3_000

      # A refundable cancellation returns the applied credit; it is absorbed
      # by the shortfall before anything becomes available again.
      cancel_group(conn, "cbg-tgt", "2027-03-01", "cbg-tgt-cancel")

      assert credit(conn, guest_id)["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "validation codes", %{conn: conn} do
      open(conn, "cbg-valid")
      pay(conn, "cbg-valid", 1_000, "cbg-valid-pay")

      # Unknown durable record.
      assert charge_back(conn, "cbg-ghost", "cbg-none")["code"] == "operation_not_found"

      # Not an applied cash payment.
      assert charge_back(conn, "open-cbg-valid", "cbg-open")["code"] == "payment_not_chargeable"

      assert submit(conn, %{
               "operation_id" => "cbg-rejected-pay",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "cbg-valid",
               "amount_cents" => 999_999
             })["code"] == "payment_exceeds_outstanding"

      assert charge_back(conn, "cbg-rejected-pay", "cbg-rejected")["code"] ==
               "payment_not_chargeable"

      # Fully reduced payments cannot be charged back.
      pay(conn, "cbg-valid", 500, "cbg-half-pay")
      assert reduce(conn, "cbg-half-pay", 500, "cbg-half-red")["status"] == "applied"

      assert charge_back(conn, "cbg-half-pay", "cbg-half-back")["code"] ==
               "payment_not_chargeable"

      # Successfully charged back payments cannot be charged back again.
      assert charge_back(conn, "cbg-valid-pay", "cbg-valid-op")["status"] == "applied"

      assert charge_back(conn, "cbg-valid-pay", "cbg-valid-op2")["code"] ==
               "payment_not_chargeable"
    end

    test "is durably idempotent", %{conn: conn} do
      open(conn, "cbg-idem")
      pay(conn, "cbg-idem", 4_000, "cbg-idem-pay")

      op = %{
        "operation_id" => "cbg-idem-op",
        "type" => "charge_back_payment",
        "payment_operation_id" => "cbg-idem-pay"
      }

      first = submit(conn, op)
      assert first["charged_back_cents"] == 4_000

      assert submit(conn, op) == first
      assert group(conn, "cbg-idem")["revision"] == 3
      assert ledger(conn)["cash_charged_back_cents"] == 4_000
      assert ledger(conn)["cash_held_cents"] == 0
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reconciles one applied cash payment without changing state", %{conn: conn} do
      open(conn, "rec-group")
      pay(conn, "rec-group", 8_000, "rec-pay")

      before = group(conn, "rec-group")["revision"]
      ledger_before = ledger(conn)

      {resp, body} = payment(conn, "rec-pay")

      assert resp.status == 200

      assert body == %{
               "data" => %{
                 "payment_operation_id" => "rec-pay",
                 "original_group_id" => "rec-group",
                 "recorded_cents" => 8_000,
                 "held_cents" => 8_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }

      assert group(conn, "rec-group")["revision"] == before
      assert ledger(conn) == ledger_before

      # The six disposition fields sum exactly to the recorded amount.
      data = body["data"]

      dispositions =
        Enum.sum([
          data["held_cents"],
          data["refunded_cents"],
          data["retained_cents"],
          data["converted_to_credit_cents"],
          data["reduced_cents"],
          data["charged_back_cents"]
        ])

      assert dispositions == data["recorded_cents"]
    end

    test "returns 404 and 422 with the documented codes", %{conn: conn} do
      assert get(conn, "/api/v1/payments/rec-ghost") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      open(conn, "rec-open")

      assert get(conn, "/api/v1/payments/open-rec-open") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert submit(conn, %{
               "operation_id" => "rec-rej",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "rec-open",
               "amount_cents" => 999_999
             })["code"] == "payment_exceeds_outstanding"

      assert get(conn, "/api/v1/payments/rec-rej") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end
end
