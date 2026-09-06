defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  describe "policy versions" do
    test "a flexible group booked before 2027 keeps the 14-day window", %{conn: conn} do
      open_group(conn)

      group = group_json(conn, "group-81")

      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2026-11-26"
    end

    test "a flexible group booked on or after 2027 uses the 30-day window", %{conn: conn} do
      open_group(conn,
        operation_id: "op-new",
        group_id: "group-new",
        occurred_on: "2027-01-01",
        arrival_on: "2027-06-01",
        departure_on: "2027-06-04"
      )

      group = group_json(conn, "group-new")

      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-05-02"

      # Cancellation on the refundable_until date is still refundable...
      operation =
        "group-new"
        |> cancel_operation("2027-05-02")
        |> Map.put("operation_id", "op-boundary")

      assert [%{"status" => "applied"}] = run_batch(conn, [operation])

      # ...and one day later is not.
      open_group(conn,
        operation_id: "op-later",
        group_id: "group-later",
        occurred_on: "2027-01-01",
        arrival_on: "2027-06-01",
        departure_on: "2027-06-04"
      )

      operation =
        "group-later"
        |> cancel_operation("2027-05-03")
        |> Map.put("operation_id", "op-too-late")

      results = run_batch(conn, [operation])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] = results
    end

    test "advance purchase is non-refundable and has no refundable date", %{conn: conn} do
      open_group(conn,
        operation_id: "op-ap",
        group_id: "group-ap",
        rate_plan: "advance_purchase"
      )

      group = group_json(conn, "group-ap")

      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-11-15",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-06-10"
          }
        ])

      assert [
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2027-06-10",
                 "new_departure_on" => "2027-06-13",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-05-27",
                 "revision" => 2
               }
             ] = results
    end
  end

  describe "cancel_group with refund_method" do
    test "omitting refund_method still refunds cash", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 5000)])

      result = cancel(conn, "op-cancel", "2026-11-20")

      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
    end

    test "an unknown refund method is an invalid operation", %{conn: conn} do
      open_group(conn)

      operation =
        "group-81"
        |> cancel_operation("2026-11-20")
        |> Map.put("refund_method", "bitcoin")
        |> Map.put("operation_id", "op-bad")

      results = run_batch(conn, [operation])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results

      assert group_json(conn, "group-81")["status"] == "active"
    end

    test "a refundable cancellation converts cash into a credit lot with the bonus", %{
      conn: conn
    } do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 5555)])

      result = cancel_with_method(conn, "op-cancel", "2026-11-26")

      # The 10% bonus rounds half up: 555.5 -> 556, so the lot is worth 6111.
      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 6111,
               "revision" => 3
             }

      # Held cash moved to the converted total instead of refunded or retained.
      assert ledger_json(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5555,
               "credit_liability_cents" => 6111
             }

      # Available through 2027-11-26 (365 days after cancellation); it expires 2027-11-27.
      assert guest_credit_json(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 6111,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 6111,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }
    end

    test "hotel credit cannot bypass a non-refundable policy", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 5000)])

      operation =
        "group-81"
        |> cancel_operation("2026-12-01")
        |> Map.put("refund_method", "hotel_credit")
        |> Map.put("operation_id", "op-cancel")

      results = run_batch(conn, [operation])

      assert results == [
               %{
                 "operation_id" => "op-cancel",
                 "status" => "rejected",
                 "code" => "refund_method_not_available",
                 "group_id" => "group-81"
               }
             ]

      group = group_json(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5000
      assert ledger_json(conn)["cash_held_cents"] == 5000
    end

    test "the revision is checked before the refund method rule", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 5000)])

      operation =
        "group-81"
        |> cancel_operation("2026-12-01")
        |> Map.put("refund_method", "hotel_credit")
        |> Map.put("expected_revision", 1)
        |> Map.put("operation_id", "op-stale")

      results = run_batch(conn, [operation])

      assert [%{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2}] =
               results
    end
  end

  describe "apply_hotel_credit" do
    test "redeems credit into the outstanding deposit and reports the result", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-cancel", 10_000)

      results = run_batch(conn, [credit_operation("op-use", "group-b", "2026-12-01", 4000)])

      assert results == [
               %{
                 "operation_id" => "op-use",
                 "status" => "applied",
                 "group_id" => "group-b",
                 "amount_cents" => 4000,
                 "outstanding_deposit_cents" => 15_500,
                 "revision" => 2
               }
             ]

      group = group_json(conn, "group-b")
      assert group["deposit_paid_cents"] == 4000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 4000

      assert %{"available_cents" => 7000} = guest_credit_json(conn, "guest-22")
    end

    test "consumes lots by earliest expiry, then by source operation id", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "cancel-late", 3000, cancelled_on: "2026-12-01")
      issue_credit(conn, "cancel-early", 3000, cancelled_on: "2026-11-01")

      run_batch(conn, [credit_operation("op-use", "group-b", "2026-12-05", 4000)])

      # The earliest-expiring lot is drained completely.
      assert lots(conn) == [{"cancel-late", 2600}]

      # Two lots expiring on the same day are consumed in source-operation order.
      issue_credit(conn, "cancel-b", 1000, cancelled_on: "2026-12-10")
      issue_credit(conn, "cancel-a", 1000, cancelled_on: "2026-12-10")

      run_batch(conn, [credit_operation("op-tie", "group-b", "2026-12-15", 3200)])

      # 2600 from cancel-late plus 600 from cancel-a, leaving cancel-b untouched.
      assert lots(conn) == [{"cancel-a", 500}, {"cancel-b", 1100}]
    end

    test "rejects more credit than the guest holds with insufficient_credit", %{conn: conn} do
      open_second_group(conn)
      # 1000 of cash converts into a 1100-cent lot.
      issue_credit(conn, "op-cancel", 1000)

      results = run_batch(conn, [credit_operation("op-short", "group-b", "2026-12-01", 1101)])

      assert [%{"status" => "rejected", "code" => "insufficient_credit", "group_id" => "group-b"}] =
               results

      assert group_json(conn, "group-b")["revision"] == 1
    end

    test "rejects credit beyond the outstanding deposit", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-cancel", 30_000)

      results = run_batch(conn, [credit_operation("op-over", "group-b", "2026-12-01", 19_501)])

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] = results

      assert guest_credit_json(conn, "guest-22")["available_cents"] == 33_000
    end

    test "rejects unusable amounts", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-cancel", 30_000)

      results =
        run_batch(conn, [
          credit_operation("op-zero", "group-b", "2026-12-01", 0),
          credit_operation("op-negative", "group-b", "2026-12-01", -5),
          credit_operation("op-string", "group-b", "2026-12-01", "100")
        ])

      assert Enum.all?(results, &(&1["code"] == "invalid_amount"))
    end

    test "rejects inactive or missing groups", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-cancel", 30_000)
      cancel(conn, "op-cancel-group-b", "2026-11-01", "group-b")

      results =
        run_batch(conn, [
          credit_operation("op-inactive", "group-b", "2026-12-01", 100),
          credit_operation("op-missing", "ghost", "2026-12-01", 100)
        ])

      codes = Enum.map(results, & &1["code"])

      assert codes == ["group_not_active", "group_not_found"]
    end

    test "expiry follows the operation's occurred_on date", %{conn: conn} do
      open_second_group(conn)

      # A lot that has already expired relative to the later application date.
      issue_credit(conn, "op-old-cancel", 5000, cancelled_on: "2025-11-01")

      results = run_batch(conn, [credit_operation("op-expired", "group-b", "2026-12-01", 100)])

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] = results

      # Still usable on a date before its expiry.
      results = run_batch(conn, [credit_operation("op-valid", "group-b", "2026-10-31", 100)])

      assert [%{"status" => "applied"}] = results
    end

    test "follows the revision contract", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-cancel", 30_000)

      results =
        run_batch(conn, [
          credit_operation("op-first", "group-b", "2026-12-01", 100)
          |> Map.put("expected_revision", 1),
          credit_operation("op-stale", "group-b", "2026-12-01", 100)
          |> Map.put("expected_revision", 1),
          credit_operation("op-second", "group-b", "2026-12-01", 100)
          |> Map.put("expected_revision", 2)
        ])

      assert [
               %{"status" => "applied", "revision" => 2},
               %{"status" => "rejected", "code" => "stale_revision"},
               %{"status" => "applied", "revision" => 3}
             ] = results
    end
  end

  describe "settling a group funded by credit" do
    test "a refundable cash cancellation restores applied credit without a second bonus", %{
      conn: conn
    } do
      open_second_group(conn)
      issue_credit(conn, "op-issue", 10_000)
      run_batch(conn, [credit_operation("op-use", "group-b", "2026-12-01", 11_000)])
      run_batch(conn, [payment("op-cash-b", "group-b", 5000)])

      result = cancel(conn, "op-cancel-b", "2026-11-15", "group-b")

      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # The full lot is available again; no extra credit was created.
      assert guest_credit_json(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-issue",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-17"
                 }
               ]
             }
    end

    test "a refundable hotel_credit cancellation refunds cash as credit and restores applied credit",
         %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-issue", 4000)
      run_batch(conn, [credit_operation("op-use", "group-b", "2026-12-01", 4400)])
      run_batch(conn, [payment("op-cash-b", "group-b", 2000)])

      result = cancel_with_method(conn, "op-cancel-b", "2026-11-15", "group-b")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      # Only the cash portion receives the bonus.
      assert result["credit_issued_cents"] == 2200

      # Ordered by expiry: the new lot (issued 2026-11-15) before the restored one
      # (issued 2026-11-16). The applied credit never received a second bonus.
      assert lots(conn) == [{"op-cancel-b", 2200}, {"op-issue", 4400}]
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn, "op-issue", 4000)
      run_batch(conn, [credit_operation("op-use", "group-b", "2026-12-01", 4400)])
      run_batch(conn, [payment("op-cash-b", "group-b", 2000)])

      result = cancel(conn, "op-cancel-b", "2026-12-09", "group-b")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 2000
      assert result["credit_issued_cents"] == 0

      assert guest_credit_json(conn, "guest-22")["available_cents"] == 0

      assert ledger_json(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 2000,
               "cash_converted_to_credit_cents" => 4000,
               "credit_liability_cents" => 0
             }
    end

    test "restored credit whose expiry already passed reduces the liability", %{conn: conn} do
      open_second_group(conn)

      # Issued 2025-11-01, so the lot expires 2026-11-02.
      issue_credit(conn, "op-old-issue", 4000, cancelled_on: "2025-11-01")
      run_batch(conn, [credit_operation("op-use", "group-b", "2026-06-01", 4400)])

      assert ledger_json(conn)["credit_liability_cents"] == 4400

      # A refundable cancellation after the lot's expiry restores the amount to a
      # lot that immediately expires, so nothing becomes available again.
      result = cancel(conn, "op-cancel-b", "2026-11-20", "group-b")

      assert result["refunded_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # Read as of a date after the restored lot's expiry.
      after_expiry =
        conn
        |> get_guest_credit("guest-22", on: "2026-12-01")
        |> json_response(200)
        |> Map.fetch!("data")

      assert after_expiry["available_cents"] == 0

      expired_liability =
        conn |> get_ledger(on: "2026-12-01") |> json_response(200) |> Map.fetch!("data")

      assert expired_liability["credit_liability_cents"] == 0
    end
  end

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "omits exhausted lots and honors the on parameter", %{conn: conn} do
      open_group(conn)
      issue_credit(conn, "op-small", 500)
      issue_credit(conn, "op-big", 5000, cancelled_on: "2026-11-01")
      run_batch(conn, [credit_operation("op-spend", "group-81", "2026-11-05", 550)])

      data = guest_credit_json(conn, "guest-22")

      assert data["available_cents"] == 5500

      # The spend came off the earliest-expiring lot.
      assert lots(conn) == [{"op-big", 4950}, {"op-small", 550}]

      # As of a date after everything expired nothing is available.
      conn = get_guest_credit(conn, "guest-22", on: "2028-01-01")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["available_cents"] == 0
      assert data["lots"] == []
    end

    test "a guest without credit reads as empty", %{conn: conn} do
      conn = get_guest_credit(conn, "nobody")

      assert json_response(conn, 200) == %{
               "data" => %{"guest_id" => "nobody", "available_cents" => 0, "lots" => []}
             }
    end
  end

  describe "ledger credit totals" do
    test "credit liability counts applied credit until settlement resolves it", %{conn: conn} do
      open_group(conn)
      issue_credit(conn, "op-issue", 4000)
      assert ledger_json(conn)["credit_liability_cents"] == 4400

      # Available credit expires with time...
      expired =
        conn |> get_ledger(on: "2030-01-01") |> json_response(200) |> Map.fetch!("data")

      assert expired["credit_liability_cents"] == 0

      run_batch(conn, [credit_operation("op-use", "group-81", "2026-12-01", 4400)])
      assert ledger_json(conn)["credit_liability_cents"] == 4400

      # ...but credit applied to an active group never expires while it funds it.
      still_funding =
        conn |> get_ledger(on: "2030-01-01") |> json_response(200) |> Map.fetch!("data")

      assert still_funding["credit_liability_cents"] == 4400
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp open_group(conn, overrides \\ %{}) do
    assert [%{"status" => "applied"}] = run_batch(conn, [open_operation(overrides)])
    :ok
  end

  defp open_second_group(conn) do
    open_group(conn, operation_id: "op-open-b", group_id: "group-b")
  end

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn, group_id) do
    %{"data" => group} = conn |> get_group(group_id) |> json_response(200)
    group
  end

  defp guest_credit_json(conn, guest_id) do
    %{"data" => data} = conn |> get_guest_credit(guest_id) |> json_response(200)
    data
  end

  defp lots(conn) do
    Enum.map(guest_credit_json(conn, "guest-22")["lots"], fn lot ->
      {lot["source_operation_id"], lot["remaining_cents"]}
    end)
  end

  defp ledger_json(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
  end

  # Opens a source group for guest-22, funds it fully with cash, and cancels it
  # refundably with hotel credit so guest-22 holds a fresh lot worth 110% of the cash.
  defp issue_credit(conn, operation_id, cash_cents, opts \\ []) do
    cancelled_on = Keyword.get(opts, :cancelled_on, "2026-11-16")
    group_id = "group-src-" <> operation_id

    arrival_on = Date.to_iso8601(Date.add(parse_date!(cancelled_on), 60))

    open_group(conn,
      operation_id: "open-" <> operation_id,
      group_id: group_id,
      arrival_on: arrival_on,
      departure_on: Date.to_iso8601(Date.add(parse_date!(arrival_on), 1)),
      # One night at 5x the cash makes the flexible deposit equal to the cash,
      # so the full amount can be paid in before converting it.
      rooms: [%{"room_id" => "room-x", "nightly_rate_cents" => cash_cents * 5}]
    )

    run_batch(conn, [payment("pay-" <> operation_id, group_id, cash_cents)])

    result = cancel_with_method(conn, operation_id, cancelled_on, group_id)

    assert result["credit_issued_cents"] == bonus(cash_cents)
    result
  end

  defp parse_date!(value), do: Date.from_iso8601!(value)

  defp bonus(cash_cents), do: div(cash_cents * 220 + 100, 200)

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp payment_operation(operation_id, amount_cents),
    do: payment(operation_id, "group-81", amount_cents)

  defp cancel(conn, operation_id, occurred_on, group_id \\ "group-81") do
    operation =
      cancel_operation(group_id, occurred_on)
      |> Map.put("operation_id", operation_id)

    assert [%{"status" => "applied"} = result] = run_batch(conn, [operation])
    result
  end

  defp cancel_operation(group_id, occurred_on) do
    %{
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp cancel_with_method(conn, operation_id, occurred_on, group_id \\ "group-81") do
    operation =
      cancel_operation(group_id, occurred_on)
      |> Map.put("operation_id", operation_id)
      |> Map.put("refund_method", "hotel_credit")

    assert [%{"status" => "applied"} = result] = run_batch(conn, [operation])
    result
  end

  defp credit_operation(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
