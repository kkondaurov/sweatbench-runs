defmodule GroupStayWeb.ChargebackTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp results(conn), do: json_response(conn, 200)["results"]

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  defp open_group_op(op_id, group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => op_id,
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
  end

  defp open_group(conn, op_id, group_id, overrides \\ %{}) do
    result = single_result(conn, [open_group_op(op_id, group_id, overrides)])
    assert result["status"] == "applied"
    result
  end

  defp pay(conn, op_id, group_id, amount_cents, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => op_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp cancel(conn, op_id, group_id, occurred_on, refund_method \\ "cash") do
    result =
      single_result(conn, [
        %{
          "operation_id" => op_id,
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "refund_method" => refund_method
        }
      ])

    assert result["status"] == "applied"
    result
  end

  defp apply_credit(conn, op_id, group_id, amount_cents, occurred_on \\ "2026-10-05") do
    result =
      single_result(conn, [
        %{
          "operation_id" => op_id,
          "type" => "apply_hotel_credit",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    result
  end

  defp chargeback_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp chargeback(conn, overrides \\ %{}) do
    result = single_result(conn, [chargeback_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "charge_back_payment" do
    test "reverses held cash on an active group and reopens the deposit", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      result = chargeback(conn)

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 5000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["deposit_paid_cents"] == 0

      [room_a, _room_b] = group["rooms"]
      assert room_a["cash_paid_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000

      assert get_payment(conn, "op-pay")["held_cents"] == 0
      assert get_payment(conn, "op-pay")["charged_back_cents"] == 5000
    end

    test "moves refunded cash to charged-back cash without reissuing anything", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)
      cancel(conn, "op-cancel", "group-81", "2026-11-26")

      assert get_ledger(conn)["cash_refunded_cents"] == 5000

      result = chargeback(conn)
      assert result["charged_back_cents"] == 5000
      assert result["group_id"] == "group-81"
      assert result["revision"] == 4
      # The group is cancelled; its outstanding deposit stays gone.
      assert result["outstanding_deposit_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
      assert ledger["cash_held_cents"] == 0

      statement = get_payment(conn, "op-pay")
      assert statement["refunded_cents"] == 0
      assert statement["charged_back_cents"] == 5000
    end

    test "moves retained cash to charged-back cash", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)
      cancel(conn, "op-cancel", "group-81", "2026-11-27")

      assert get_ledger(conn)["cash_retained_cents"] == 5000

      result = chargeback(conn)
      assert result["charged_back_cents"] == 5000

      ledger = get_ledger(conn)
      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "revokes the credit entitlement created by converted cash", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 1000)

      assert cancel(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")[
               "credit_issued_cents"
             ] == 1100

      assert get_credit(conn, "guest-22")["available_cents"] == 1100
      assert get_ledger(conn)["credit_liability_cents"] == 1100

      result = chargeback(conn)
      assert result["charged_back_cents"] == 1000

      # The entitlement is gone from the lot's remaining balance.
      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 1000
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0

      statement = get_payment(conn, "op-pay")
      assert statement["converted_to_credit_cents"] == 0
      assert statement["charged_back_cents"] == 1000
    end

    test "reverses every remaining disposition except reduced cash", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 13000)

      # 4000 retained on room-b, 1000 reduced, 8000 still held on room-a.
      single_result(conn, [
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81",
          "room_ids" => ["room-b"]
        }
      ])

      assert single_result(conn, [
               %{
                 "operation_id" => "op-reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "op-pay",
                 "amount_cents" => 1000
               }
             ])["status"] == "applied"

      result = chargeback(conn)
      assert result["charged_back_cents"] == 12000
      assert result["outstanding_deposit_cents"] == 9000

      statement = get_payment(conn, "op-pay")
      assert statement["recorded_cents"] == 13000
      assert statement["held_cents"] == 0
      assert statement["retained_cents"] == 0
      assert statement["reduced_cents"] == 1000
      assert statement["charged_back_cents"] == 12000

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_reduced_cents"] == 1000
      assert ledger["cash_charged_back_cents"] == 12000
    end
  end

  describe "credit clawbacks" do
    # guest-22 cancels group-81 as hotel credit, applies part of the lot to
    # group-target, and then the original payment is charged back.
    setup %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      pay(conn, "op-pay", "group-81", 1000)
      cancel(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")

      open_group(conn, "op-open-target", "group-target")

      :ok
    end

    test "unrecovered clawback becomes a current shortfall while credit stays applied",
         %{conn: conn} do
      apply_credit(conn, "op-credit", "group-target", 600)

      # The lot holds 500; the payment's entitlement is 1100.
      assert chargeback(conn)["charged_back_cents"] == 1000

      # The whole remaining balance was removed from the lot.
      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      # Liability still includes the applied credit covered by the shortfall.
      assert ledger["credit_liability_cents"] == 600
      assert ledger["credit_shortfall_cents"] == 600

      # The group funded by the credit is unchanged.
      group = get_group(conn, "group-target")
      assert group["revision"] == 2
      assert group["credit_paid_cents"] == 600
      assert group["status"] == "active"
    end

    test "non-refundable settlement of the credit reduces the shortfall", %{conn: conn} do
      apply_credit(conn, "op-credit", "group-target", 600)
      chargeback(conn)
      assert get_ledger(conn)["credit_shortfall_cents"] == 600

      # Inside group-target's window: the applied credit is consumed.
      cancel(conn, "op-cancel-target", "group-target", "2026-12-01")

      ledger = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "restored credit extinguishes unrecovered clawback before becoming available",
         %{conn: conn} do
      apply_credit(conn, "op-credit", "group-target", 600)
      chargeback(conn)

      # Refundable cancellation restores the credit; the shortfall absorbs
      # all of it.
      cancel(conn, "op-cancel-target", "group-target", "2026-11-01")

      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "an absorbed restoration leaves no shortfall once the credit returns", %{conn: conn} do
      apply_credit(conn, "op-credit", "group-target", 300)
      chargeback(conn)

      # Entitlement 1100, remaining 800 at chargeback: unrecovered 300.
      assert get_ledger(conn)["credit_shortfall_cents"] == 300

      cancel(conn, "op-cancel-target", "group-target", "2026-11-01")

      assert get_credit(conn, "guest-22")["available_cents"] == 0
      assert get_ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "successive restorations to the same lot observe each other's absorption",
         %{conn: conn} do
      # A lot from two payments; group-target funds one room with two
      # applications from that lot.
      open_group(conn, "op-open-big", "group-big", %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      pay(conn, "op-pay-big-1", "group-big", 1000)
      pay(conn, "op-pay-big-2", "group-big", 1000)

      # Cancelled earlier than the setup group so this lot expires first
      # and is consumed first.
      cancel(conn, "op-cancel-big", "group-big", "2026-11-20", "hotel_credit")

      apply_credit(conn, "op-credit-1", "group-target", 600, "2026-11-27")
      apply_credit(conn, "op-credit-2", "group-target", 900, "2026-11-27")

      # Entitlement 1100 against 700 remaining: unrecovered 400.
      chargeback(conn, %{
        "operation_id" => "op-chargeback-big",
        "payment_operation_id" => "op-pay-big-1"
      })

      assert get_ledger(conn)["credit_shortfall_cents"] == 400

      # Settling the room restores both applications at once: the first
      # extinguishes the 400 clawback and keeps 200, the second keeps all
      # 900. Together they return the lot to 1100, alongside the untouched
      # setup lot.
      single_result(conn, [
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-target",
          "room_ids" => ["room-a"]
        }
      ])

      credit = get_credit(conn, "guest-22")
      assert credit["available_cents"] == 2200

      ledger = get_ledger(conn)
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 2200
    end

    test "only the excess over the unrecovered clawback becomes available", %{conn: conn} do
      # Two payments create one lot; charging back only the first payment
      # leaves a clawback smaller than the applied credit. Cancelled earlier
      # than the setup lot so it is consumed first.
      open_group(conn, "op-open-big", "group-big", %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      pay(conn, "op-pay-big-1", "group-big", 1000)
      pay(conn, "op-pay-big-2", "group-big", 1000)
      cancel(conn, "op-cancel-big", "group-big", "2026-11-20", "hotel_credit")

      # The lot is worth 2200; group-target applies 1500.
      apply_credit(conn, "op-credit-big", "group-target", 1500, "2026-11-27")

      assert chargeback(conn, %{
               "operation_id" => "op-chargeback-big",
               "payment_operation_id" => "op-pay-big-1"
             })["charged_back_cents"] == 1000

      # Entitlement 1100 against 700 remaining: unrecovered 400.
      assert get_ledger(conn)["credit_shortfall_cents"] == 400

      # Restoring 1500 extinguishes the 400 clawback first; the remaining
      # 1100 becomes available again, alongside the untouched setup lot.
      cancel(conn, "op-cancel-target", "group-target", "2026-11-01")

      credit = get_credit(conn, "guest-22")
      assert credit["available_cents"] == 2200

      ledger = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 2200
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "absorption occurs before checking the lot's expiry", %{conn: conn} do
      open_group(conn, "op-open-big", "group-big", %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      pay(conn, "op-pay-big-1", "group-big", 1000)
      pay(conn, "op-pay-big-2", "group-big", 1000)

      # The lot expires 2027-10-04.
      cancel(conn, "op-cancel-big", "group-big", "2026-10-04", "hotel_credit")
      apply_credit(conn, "op-credit-big", "group-target", 1500, "2026-10-05")

      chargeback(conn, %{
        "operation_id" => "op-chargeback-big",
        "payment_operation_id" => "op-pay-big-1"
      })

      assert get_ledger(conn)["credit_shortfall_cents"] == 400

      # Move group-target's arrival far enough that a late cancellation is
      # still refundable, then cancel after the lot's expiry.
      assert single_result(conn, [
               %{
                 "operation_id" => "op-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-target",
                 "new_arrival_on" => "2028-01-10"
               }
             ])["status"] == "applied"

      cancel(conn, "op-cancel-target", "group-target", "2027-10-05")

      # The restoration absorbed the clawback before expiry was considered;
      # the excess expired under the existing rules. Only the untouched
      # setup lot remains.
      assert get_credit(conn, "guest-22")["available_cents"] == 1100

      ledger = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 1100
      assert ledger["credit_shortfall_cents"] == 0
    end
  end

  describe "entitlement attribution" do
    test "entitlements telescope exactly to the issued lot", %{conn: conn} do
      open_group(conn, "op-open", "group-81", %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      pay(conn, "op-pay-1", "group-81", 1005)
      pay(conn, "op-pay-2", "group-81", 1004)

      # 2009 cash becomes a 2210 lot.
      assert cancel(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")[
               "credit_issued_cents"
             ] == 2210

      # First payment's entitlement: V(1005) = 1005 + 101 = 1106.
      assert chargeback(conn, %{
               "operation_id" => "op-chargeback-1",
               "payment_operation_id" => "op-pay-1"
             })["charged_back_cents"] == 1005

      [lot] = get_credit(conn, "guest-22")["lots"]
      assert lot["remaining_cents"] == 1104

      # The second payment's entitlement: V(2009) - V(1005) = 1104.
      assert chargeback(conn, %{
               "operation_id" => "op-chargeback-2",
               "payment_operation_id" => "op-pay-2"
             })["charged_back_cents"] == 1004

      assert get_credit(conn, "guest-22")["lots"] == []

      ledger = get_ledger(conn)
      assert ledger["cash_charged_back_cents"] == 2009
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "entitlement follows durable-record commit order, not occurred_on", %{conn: conn} do
      open_group(conn, "op-open", "group-81", %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      # Committed first with a later occurred_on.
      pay(conn, "op-pay-first", "group-81", 1003, %{"occurred_on" => "2026-10-06"})
      pay(conn, "op-pay-second", "group-81", 1003, %{"occurred_on" => "2026-10-05"})

      # 2006 cash becomes a 2207 lot.
      cancel(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")

      # Commit order makes the first payment's entitlement V(1003) = 1103.
      # Ordering by occurred_on would make it V(2006) - V(1003) = 1104.
      chargeback(conn, %{"payment_operation_id" => "op-pay-first"})

      [lot] = get_credit(conn, "guest-22")["lots"]
      assert lot["remaining_cents"] == 2207 - 1103

      # The second payment takes the remainder.
      chargeback(conn, %{
        "operation_id" => "op-chargeback-2",
        "payment_operation_id" => "op-pay-second"
      })

      assert get_credit(conn, "guest-22")["lots"] == []
    end

    test "entitlements are calculated independently for each lot", %{conn: conn} do
      open_group(conn, "op-open", "group-81")

      # Two partial settlements convert the same payment's cash into two
      # separate lots.
      pay(conn, "op-pay", "group-81", 13000)

      assert single_result(conn, [
               %{
                 "operation_id" => "op-cancel-rooms-1",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group-81",
                 "room_ids" => ["room-a"],
                 "refund_method" => "hotel_credit"
               }
             ])["credit_issued_cents"] == 9900

      assert single_result(conn, [
               %{
                 "operation_id" => "op-cancel-rooms-2",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group-81",
                 "room_ids" => ["room-b"],
                 "refund_method" => "hotel_credit"
               }
             ])["credit_issued_cents"] == 4400

      # The single payment contributed all of both lots; each entitlement
      # equals its lot.
      assert chargeback(conn)["charged_back_cents"] == 13000
      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 13000
      assert ledger["credit_liability_cents"] == 0
    end
  end

  describe "rejections" do
    test "rejects targets that cannot be charged back", %{conn: conn} do
      open_group(conn, "op-open", "group-81")

      # No durable record exists.
      result =
        single_result(conn, [
          chargeback_op(%{
            "operation_id" => "op-cb-nobody",
            "payment_operation_id" => "op-nobody"
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_not_found"

      # A record that is not a payment operation.
      result =
        single_result(conn, [
          chargeback_op(%{"operation_id" => "op-cb-open", "payment_operation_id" => "op-open"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"

      # A rejected payment.
      assert single_result(conn, [
               %{
                 "operation_id" => "op-pay-bad",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 0
               }
             ])["code"] == "invalid_amount"

      result =
        single_result(conn, [
          chargeback_op(%{"operation_id" => "op-cb-bad", "payment_operation_id" => "op-pay-bad"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects a fully reduced payment", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      assert single_result(conn, [
               %{
                 "operation_id" => "op-reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "op-pay",
                 "amount_cents" => 5000
               }
             ])["status"] == "applied"

      result = single_result(conn, [chargeback_op()])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"
    end

    test "rejects a payment that was already charged back", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      assert chargeback(conn)["charged_back_cents"] == 5000

      result = single_result(conn, [chargeback_op(%{"operation_id" => "op-chargeback-2"})])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_chargeable"

      assert get_payment(conn, "op-pay")["charged_back_cents"] == 5000
    end

    test "rejects a stale revision before the chargeback domain rules", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      result =
        single_result(conn, [
          chargeback_op(%{"expected_revision" => 99})
        ])

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 2
             }

      assert get_payment(conn, "op-pay")["held_cents"] == 5000
      assert get_group(conn, "group-81")["revision"] == 2
    end

    test "rejects a malformed operation", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      for {op, index} <-
            Enum.with_index([
              Map.delete(chargeback_op(%{}), "payment_operation_id"),
              %{chargeback_op(%{}) | "payment_operation_id" => 42}
            ]) do
        op = Map.put(op, "operation_id", "op-malformed-#{index}")
        [result] = results(submit(conn, [op]))
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert get_group(conn, "group-81")["revision"] == 2
    end
  end

  describe "durability" do
    test "a chargeback is durably idempotent and bumps the revision exactly once", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      first = chargeback(conn)
      retry = single_result(conn, [chargeback_op()])
      assert retry == first

      assert get_group(conn, "group-81")["revision"] == 3
      assert get_ledger(conn)["cash_charged_back_cents"] == 5000

      # A remembered rejection replays.
      rejected =
        single_result(conn, [
          chargeback_op(%{
            "operation_id" => "op-cb-nobody",
            "payment_operation_id" => "op-nobody"
          })
        ])

      assert rejected["code"] == "operation_not_found"

      assert single_result(conn, [
               chargeback_op(%{
                 "operation_id" => "op-cb-nobody",
                 "payment_operation_id" => "op-nobody"
               })
             ]) == rejected
    end

    test "retrying the original payment still returns its exact original result", %{conn: conn} do
      open_group(conn, "op-open", "group-81")

      original = pay(conn, "op-pay", "group-81", 5000)
      chargeback(conn)

      assert single_result(conn, [
               %{
                 "operation_id" => "op-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 5000
               }
             ]) == original

      assert get_payment(conn, "op-pay")["charged_back_cents"] == 5000
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 0
    end
  end
end
