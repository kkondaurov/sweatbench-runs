defmodule GroupStayWeb.PaymentCorrectionsTest do
  use GroupStayWeb.ConnCase

  @booked_on "2026-10-03"

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay-1", "group-81", 5_000)])
      submit(conn, [payment_op("op-pay-2", "group-81", 7_000)])

      # op-pay-2 holds 4_000 on room-a and 3_000 on room-b; a reduction must
      # take from room-b first
      result = only_result(submit(conn, [reduce_op("op-reduce", "op-pay-2", 5_000)]))

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay-2",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 12_500,
               "revision" => 4
             }

      group = get_group(conn, "group-81")

      # room-b's whole allocation went first, then part of room-a's
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [7_000, 0]
      assert group["deposit_paid_cents"] == 7_000
      assert ledger(conn)["cash_held_cents"] == 7_000
      assert ledger(conn)["cash_reduced_cents"] == 5_000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 6_000)])

      assert only_result(submit(conn, [reduce_op("op-r1", "op-pay", 2_500)]))["status"] ==
               "applied"

      assert only_result(submit(conn, [reduce_op("op-r2", "op-pay", 3_000)]))["status"] ==
               "applied"

      # the exact remaining held portion is still valid
      result = only_result(submit(conn, [reduce_op("op-r3", "op-pay", 500)]))

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 19_500
      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_reduced_cents"] == 6_000
      assert get_group(conn, "group-81")["revision"] == 5
    end

    test "reduced rooms refill before later rooms", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay-1", "group-81", 5_000)])
      submit(conn, [payment_op("op-pay-2", "group-81", 7_000)])

      # remove all of op-pay-1 from room-a, then refill: the reopened room-a
      # gap is filled before room-b continues
      submit(conn, [reduce_op("op-reduce", "op-pay-1", 5_000)])
      submit(conn, [payment_op("op-pay-3", "group-81", 6_000)])

      group = get_group(conn, "group-81")
      # room-a was refilled to its full deposit before room-b continued
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [9_000, 4_000]
      assert statement(conn, "op-pay-3")["held_cents"] == 6_000
    end

    test "rejects with the documented codes", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 6_000)])

      assert rejection(
               submit(conn, [reduce_op("op-missing", "op-nowhere", 100)]),
               "operation_not_found"
             )

      # a non-payment operation can never be reduced
      submit(conn, [cancel_rooms_op("op-cr", "group-81", ["room-b"], "2026-11-26")])

      assert rejection(
               submit(conn, [reduce_op("op-not-payment", "op-cr", 100)]),
               "payment_not_reducible"
             )

      # a rejected payment cannot be reduced either
      submit(conn, [payment_op("op-rejected", "group-81", 999_999)])

      assert rejection(
               submit(conn, [reduce_op("op-on-rejected", "op-rejected", 100)]),
               "payment_not_reducible"
             )

      for {amount, index} <- Enum.with_index([0, -100, "100", nil]) do
        assert rejection(
                 submit(conn, [reduce_op("op-bad-#{index}", "op-pay", amount)]),
                 "invalid_amount"
               )
      end

      assert rejection(
               submit(conn, [reduce_op("op-too-much", "op-pay", 6_001)]),
               "reduction_exceeds_held_cash"
             )

      # nothing above moved any money; room-b held no cash, so cancelling it
      # only gave up its unpaid deposit
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 6_000
      assert get_group(conn, "group-81")["revision"] == 3
      assert ledger(conn)["cash_reduced_cents"] == 0
    end

    test "an applied payment with no held cash left is not reducible", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 19_500)])
      submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-26")])

      assert rejection(
               submit(conn, [reduce_op("op-reduce", "op-pay", 100)]),
               "payment_not_reducible"
             )
    end

    test "checks expected_revision against the payment's own group", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])

      result =
        only_result(
          submit(conn, [
            reduce_op("op-stale", "op-pay", 1_000) |> Map.put("expected_revision", 99)
          ])
        )

      assert result == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 2
             }

      current =
        reduce_op("op-current", "op-pay", 1_000) |> Map.put("expected_revision", 2)

      assert only_result(submit(conn, [current]))["revision"] == 3
    end

    test "is durably idempotent", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])

      op = reduce_op("op-reduce", "op-pay", 2_000)
      first = only_result(submit(conn, [op]))
      replay = only_result(submit(conn, [op]))

      assert replay == first
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 3_000
      assert get_group(conn, "group-81")["revision"] == 3
      assert ledger(conn)["cash_reduced_cents"] == 2_000
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash and reopens the outstanding deposit", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 8_000)])

      result = only_result(submit(conn, [charge_back_op("op-cb", "op-pay")]))

      assert result == %{
               "operation_id" => "op-cb",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 8_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]
      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 8_000

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 8_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 8_000
             }
    end

    test "reclassifies refunded and retained portions without reversing them", %{conn: conn} do
      apply_open!(conn, "group-refundable")
      apply_open!(conn, "group-retained", rate_plan: "advance_purchase")

      submit(conn, [payment_op("op-pay-r", "group-refundable", 4_000)])
      submit(conn, [payment_op("op-pay-t", "group-retained", 5_000)])

      submit(conn, [cancel_op("op-cancel-r", "group-refundable", "2026-11-26")])
      submit(conn, [cancel_op("op-cancel-t", "group-retained", "2026-10-05")])

      assert only_result(submit(conn, [charge_back_op("op-cb-r", "op-pay-r")]))[
               "charged_back_cents"
             ] == 4_000

      assert only_result(submit(conn, [charge_back_op("op-cb-t", "op-pay-t")]))[
               "charged_back_cents"
             ] == 5_000

      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 9_000

      # the historical refund and retention are not undone: no held cash
      # returns and the groups stay cancelled
      assert get_group(conn, "group-refundable")["status"] == "cancelled"
      assert get_group(conn, "group-retained")["status"] == "cancelled"

      assert statement(conn, "op-pay-r")["refunded_cents"] == 0
      assert statement(conn, "op-pay-r")["charged_back_cents"] == 4_000
    end

    test "revokes converted principal's credit entitlement from its lot", %{conn: conn} do
      # two payments fund one group whose refundable cancellation converts
      # their combined cash into one lot worth bonus(9_000)
      apply_open!(conn, "group-src")
      submit(conn, [payment_op("op-pay-a", "group-src", 4_000)])
      submit(conn, [payment_op("op-pay-b", "group-src", 5_000)])

      submit(conn, [
        cancel_op("op-cancel", "group-src", "2026-11-26")
        |> Map.put("refund_method", "hotel_credit")
      ])

      assert guest_credit(conn, "guest-22")["available_cents"] == 9_900

      assert only_result(submit(conn, [charge_back_op("op-cb-a", "op-pay-a")]))[
               "charged_back_cents"
             ] == 4_000

      # entitlement telescopes: bonus(4_000) - bonus(0) = 4_400
      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 5_000
      assert ledger(conn)["credit_liability_cents"] == 5_500

      assert only_result(submit(conn, [charge_back_op("op-cb-b", "op-pay-b")]))[
               "charged_back_cents"
             ] == 5_000

      # bonus(9_000) - bonus(4_000) = 9_900 - 4_400 = 5_500
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 9_000
    end

    test "credit applied to active groups becomes a shortfall that settles down", %{
      conn: conn
    } do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")

      # 6_000 of the lot funds an active group; 5_000 funds another group and
      # is then consumed by a non-refundable cancellation
      apply_open!(conn, "group-holder")
      submit(conn, [credit_op("op-hold", "group-holder", 6_000)])

      apply_open!(conn, "group-spender", rate_plan: "advance_purchase")
      submit(conn, [credit_op("op-spend", "group-spender", 5_000)])

      submit(conn, [cancel_op("op-cancel-spender", "group-spender", "2026-11-01")])

      # clawback cannot recall credit funding active groups, so the whole
      # entitlement becomes unrecovered clawback
      submit(conn, [charge_back_op("op-cb", "op-pay-group-src")])

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 6_000

      # liability keeps including credit applied to active groups, even the
      # portion covered by a shortfall
      assert ledger(conn)["credit_liability_cents"] == 6_000

      # a refundable settlement restores the holder's credit, which goes to
      # extinguishing the unrecovered clawback instead of becoming available
      submit(conn, [cancel_op("op-cancel-holder", "group-holder", "2026-11-26")])

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "restored credit extinguishes unrecovered clawback before becoming available", %{
      conn: conn
    } do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")

      apply_open!(conn, "group-holder")
      submit(conn, [credit_op("op-use", "group-holder", 10_000)])

      # spend the free 1_000 elsewhere so the clawback cannot recover it
      apply_open!(conn, "group-freebie",
        rooms: [%{"room_id" => "room-tiny", "nightly_rate_cents" => 8}]
      )

      submit(conn, [credit_op("op-free", "group-freebie", 1_000)])

      submit(conn, [charge_back_op("op-cb", "op-pay-group-src")])

      assert guest_credit(conn, "guest-22")["available_cents"] == 0

      # refundable cancellation restores the 10_000; it all goes to
      # extinguishing the unrecovered clawback, so nothing becomes available
      submit(conn, [cancel_op("op-cancel", "group-holder", "2026-11-26")])

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "works on cancelled groups and increments only that group's revision once", %{
      conn: conn
    } do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")
      revision_before = get_group(conn, "group-src")["revision"]

      apply_open!(conn, "group-other")
      other_before = get_group(conn, "group-other")["revision"]

      assert only_result(submit(conn, [charge_back_op("op-cb", "op-pay-group-src")]))[
               "revision"
             ] == revision_before + 1

      # the chargeback does not touch groups funded by the affected credit
      assert get_group(conn, "group-other")["revision"] == other_before
    end

    test "rejects with the documented codes", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 6_000)])

      assert rejection(
               submit(conn, [charge_back_op("op-missing", "op-nowhere")]),
               "operation_not_found"
             )

      # a non-payment operation is not chargeable
      submit(conn, [reschedule_op("op-move", "group-81", "2026-12-11")])

      assert rejection(
               submit(conn, [charge_back_op("op-on-move", "op-move")]),
               "payment_not_chargeable"
             )

      # a rejected payment is not chargeable
      submit(conn, [payment_op("op-rejected", "group-81", 999_999)])

      assert rejection(
               submit(conn, [charge_back_op("op-on-rejected", "op-rejected")]),
               "payment_not_chargeable"
             )

      assert only_result(submit(conn, [charge_back_op("op-cb", "op-pay")]))["status"] == "applied"

      # already charged back
      assert rejection(
               submit(conn, [charge_back_op("op-again", "op-pay")]),
               "payment_not_chargeable"
             )
    end

    test "a fully reduced payment is not chargeable", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])
      submit(conn, [reduce_op("op-reduce", "op-pay", 5_000)])

      assert rejection(
               submit(conn, [charge_back_op("op-cb", "op-pay")]),
               "payment_not_chargeable"
             )
    end

    test "is durably idempotent", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])

      op = charge_back_op("op-cb", "op-pay")
      first = only_result(submit(conn, [op]))
      replay = only_result(submit(conn, [op]))

      assert replay == first
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
      assert get_group(conn, "group-81")["revision"] == 3
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition including zeros, summing to recorded", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 10_000)])

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 10_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "dispositions always sum exactly to recorded cash", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 10_000)])
      submit(conn, [reduce_op("op-reduce", "op-pay", 1_000)])

      # room-a holds 9_000 of the payment; converting it moves that portion
      # to converted, and the chargeback then reclassifies it again
      submit(conn, [
        cancel_rooms_op("op-cr", "group-81", ["room-a"], "2026-11-26")
        |> Map.put("refund_method", "hotel_credit")
      ])

      assert statement(conn, "op-pay")["converted_to_credit_cents"] == 9_000
      assert statement(conn, "op-pay")["held_cents"] == 0

      # charge back what is left of the payment
      submit(conn, [charge_back_op("op-cb", "op-pay")])

      s = statement(conn, "op-pay")

      dispositions =
        ~w(refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)

      assert Enum.sum([
               s["held_cents"] | Enum.map(dispositions, &Map.fetch!(s, &1))
             ]) == s["recorded_cents"]

      assert s["held_cents"] == 0
      assert s["reduced_cents"] == 1_000
      assert s["charged_back_cents"] == 9_000

      # the views agree with each other
      assert ledger(conn)["cash_reduced_cents"] == 1_000
      assert ledger(conn)["cash_charged_back_cents"] == s["charged_back_cents"]
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0

      # the lot the conversion issued lost its entitlement to the clawback
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "returns 404 for unknown or legacy funding", %{conn: conn} do
      assert conn |> get("/api/v1/payments/op-nowhere") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end

    test "returns 422 for records that are not applied cash payments", %{conn: conn} do
      apply_open!(conn, "group-81")

      # an operation that was rejected is stored but not reconcilable
      submit(conn, [payment_op("op-rejected", "group-81", 999_999)])

      submit(conn, [reschedule_op("op-move", "group-81", "2026-12-11")])
      submit(conn, [credit_op("op-use", "group-81", 1)]) |> only_result()

      for id <- ["op-rejected", "op-move", "op-use"] do
        assert conn |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
                 "error" => %{"code" => "payment_not_reconcilable"}
               }
      end
    end

    test "reading never changes state", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 5_000)])

      before = get_group(conn, "group-81")
      statement(conn, "op-pay")
      statement(conn, "op-pay")
      after_read = get_group(conn, "group-81")

      assert after_read == before
      assert ledger(conn)["cash_held_cents"] == 5_000
    end
  end

  # Helpers

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(response) do
    [result] = response["results"]
    result
  end

  defp rejection(response, code) do
    result = only_result(response)

    result["status"] == "rejected" and result["code"] == code
  end

  defp apply_open!(conn, group_id, opts \\ []) do
    result = only_result(submit(conn, [open_op(group_id, opts)]))
    assert result["status"] == "applied"
    result
  end

  defp open_op(group_id, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-" <> group_id),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, "2026-12-10"),
      "departure_on" => Keyword.get(opts, :departure_on, "2026-12-13"),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
    }
  end

  defp payment_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reschedule_op(operation_id, group_id, new_arrival_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }
  end

  defp cancel_op(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp cancel_rooms_op(operation_id, group_id, room_ids, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp credit_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_op(operation_id, payment_operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => @booked_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_op(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => @booked_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  # Cancels a freshly paid flexible group with hotel credit so guest-22 ends
  # up with a credit lot of round(cash * 110%) expiring 366 days later.
  defp issue_credit(conn, operation_id, group_id, cash_cents, occurred_on) do
    apply_open!(conn, group_id)

    if cash_cents > 0 do
      submit(conn, [payment_op("op-pay-" <> group_id, group_id, cash_cents)])
    end

    result =
      only_result(
        submit(conn, [
          cancel_op(operation_id, group_id, occurred_on)
          |> Map.put("refund_method", "hotel_credit")
        ])
      )

    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end

  defp statement(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
