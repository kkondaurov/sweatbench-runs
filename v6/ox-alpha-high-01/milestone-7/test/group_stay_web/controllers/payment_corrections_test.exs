defmodule GroupStayWeb.PaymentCorrectionsTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  # The default group has rooms room-a (deposit 9_000) and room-b (deposit
  # 10_500), 19_500 in total. It is refundable through 2026-11-26.

  describe "reduce_cash_payment" do
    test "removes held allocations in reverse fill order and reopens the deposit", %{conn: conn} do
      open_group(conn)

      run_batch(conn, [payment_operation("op-pay-1", 6_000), payment_operation("op-pay-2", 8_000)])

      assert [%{"status" => "applied"} = result] =
               run_batch(conn, [reduce_op("op-reduce", "op-pay-2", 5_000)])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay-2",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 10_500,
               "revision" => 4
             }

      # Reverse fill order removes room-b's portion of pay-2 first.
      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = group_json(conn, "group-81")["rooms"]

      assert statement(conn, "op-pay-2") |> Map.take(~w(held_cents reduced_cents)) == %{
               "held_cents" => 3_000,
               "reduced_cents" => 5_000
             }

      ledger = ledger_json(conn)
      assert ledger["cash_reduced_cents"] == 5_000
      assert ledger["cash_held_cents"] == 9_000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      assert [%{"status" => "applied"}] = run_batch(conn, [reduce_op("op-r1", "op-pay", 2_500)])
      assert [%{"status" => "applied"}] = run_batch(conn, [reduce_op("op-r2", "op-pay", 3_500)])

      statement = statement(conn, "op-pay")

      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 6_000
      assert disposition_sum(statement) == 6_000

      # Nothing held remains to reduce.
      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               run_batch(conn, [reduce_op("op-r3", "op-pay", 1)])
    end

    test "rejects unusable targets and amounts with stable codes", %{conn: conn} do
      open_group(conn)

      run_batch(conn, [
        payment_operation("op-pay", 6_000),
        %{
          "operation_id" => "op-rejected",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "amount_cents" => 999_999
        }
      ])

      results =
        run_batch(conn, [
          reduce_op("op-no-target", "op-ghost", 100),
          reduce_op("op-not-payment", "op-open", 100),
          reduce_op("op-rejected-payment", "op-rejected", 100),
          reduce_op("op-zero", "op-pay", 0),
          reduce_op("op-negative", "op-pay", -100),
          reduce_op("op-exceeds", "op-pay", 6_001)
        ])

      codes = Enum.map(results, & &1["code"])

      assert codes == [
               "operation_not_found",
               "payment_not_reducible",
               "payment_not_reducible",
               "invalid_amount",
               "invalid_amount",
               "reduction_exceeds_held_cash"
             ]

      # An amount equal to the complete held portion is valid.
      assert [%{"status" => "applied", "amount_cents" => 6_000}] =
               run_batch(conn, [reduce_op("op-full", "op-pay", 6_000)])
    end

    test "follows the revision contract derived from the original payment's group", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      stale =
        reduce_op("op-stale", "op-pay", 1_000)
        |> Map.put("expected_revision", 1)

      assert [%{"status" => "rejected", "code" => "stale_revision"} = rejection] =
               run_batch(conn, [stale])

      assert rejection["group_id"] == "group-81"
      assert rejection["expected_revision"] == 1
      assert rejection["actual_revision"] == 2
      assert group_json(conn, "group-81")["revision"] == 2

      current =
        reduce_op("op-current", "op-pay", 1_000)
        |> Map.put("expected_revision", 2)

      assert [%{"status" => "applied", "revision" => 3}] = run_batch(conn, [current])
    end

    test "retries return the exact original result without consulting current state", %{
      conn: conn
    } do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      first = reduce_op("op-reduce", "op-pay", 1_000)
      assert [%{"status" => "applied"} = stored] = run_batch(conn, [first])

      # State moves on afterwards...
      assert [%{"status" => "applied"}] =
               run_batch(conn, [reduce_op("op-later", "op-pay", 2_000)])

      # ...and the retry still replays the stored result verbatim.
      assert [%{"status" => "applied"} = replayed] = run_batch(conn, [first])
      assert replayed == stored

      corrected = first |> Map.put("amount_cents", 3_000)

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               run_batch(conn, [corrected])
    end
  end

  describe "charge_back_payment" do
    test "reverses every undisputed disposition and never rewrites the stored result", %{
      conn: conn
    } do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [reduce_op("op-reduce", "op-pay", 1_000)])

      result = charge_back(conn, "op-chb", "op-pay")

      assert result["charged_back_cents"] == 5_000
      assert result["group_id"] == "group-81"
      # The held cash was removed, so the full unpaid deposit reopens.
      assert result["outstanding_deposit_cents"] == 19_500
      assert result["revision"] == 4

      statement = statement(conn, "op-pay")

      assert statement == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 5_000
             }

      # Retrying the original payment returns its exact original result even
      # though current group state has moved on.
      assert [%{"status" => "applied"} = original] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-pay",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81",
                   "amount_cents" => 6_000
                 }
               ])

      assert original["outstanding_deposit_cents"] == 13_500
      assert original["revision"] == 2

      # Already charged back.
      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               run_batch(conn, [charge_back_op("op-chb-again", "op-pay")])
    end

    test "rejects unknown and ineligible targets", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          charge_back_op("op-ghost", "op-ghost"),
          charge_back_op("op-not-payment", "op-open")
        ])

      assert Enum.map(results, & &1["code"]) == [
               "operation_not_found",
               "payment_not_chargeable"
             ]
    end

    test "moves refunded and retained history to charged-back cash", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-12-01",
                   "group_id" => "group-81"
                 }
               ])

      assert ledger_json(conn)["cash_retained_cents"] == 6_000

      result = charge_back(conn, "op-chb", "op-pay")

      # The historical retention is not reversed or reissued; only its ledger
      # classification changes.
      assert result["charged_back_cents"] == 6_000
      assert result["outstanding_deposit_cents"] == 0

      statement = statement(conn, "op-pay")

      assert statement["retained_cents"] == 0
      assert statement["charged_back_cents"] == 6_000

      ledger = ledger_json(conn)

      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 6_000

      # Only the original payment group's revision moved, exactly once.
      assert group_json(conn, "group-81")["revision"] == 4
      assert group_json(conn, "group-81")["status"] == "cancelled"
    end

    test "revoking converted credit creates a shortfall that a restoration absorbs", %{
      conn: conn
    } do
      fund_target_with_credit(conn)

      # The conversion's entitlement is revoked from the lot's remaining
      # balance; the part applied to the active target becomes a shortfall.
      result = charge_back(conn, "op-chb", "pay-src")

      assert result["charged_back_cents"] == 10_000
      assert lots(conn) == []

      ledger = ledger_json(conn)

      assert ledger["credit_shortfall_cents"] == 11_000
      assert ledger["credit_liability_cents"] == 11_000
      assert ledger["cash_charged_back_cents"] == 10_000

      # Groups funded by the affected credit are untouched.
      assert group_json(conn, "group-81")["revision"] == 2
      assert group_json(conn, "group-src-op-src")["revision"] == 4

      # A refundable settlement restores the applied credit, which is absorbed
      # by the unrecovered clawback instead of becoming available again.
      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-cancel-t",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-20",
                   "group_id" => "group-81"
                 }
               ])

      ledger = ledger_json(conn)

      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "non-refundable settlement reduces the shortfall automatically", %{conn: conn} do
      fund_target_with_credit(conn)

      assert [%{"status" => "applied"}] =
               run_batch(conn, [charge_back_op("op-chb", "pay-src")])

      assert ledger_json(conn)["credit_shortfall_cents"] == 11_000

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-cancel-t",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-12-01",
                   "group_id" => "group-81"
                 }
               ])

      ledger = ledger_json(conn)

      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns the exact current disposition of one payment", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      assert conn |> get_payment("op-pay") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 6_000,
                 "held_cents" => 6_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end

    test "returns 404 without a durable record and 422 for non-cash records", %{conn: conn} do
      open_group(conn)

      assert get_payment(conn, "op-ghost") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert get_payment(conn, "op-open") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    test "dispositions agree with group and ledger views", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-a", 6_000)])

      open_group(conn,
        operation_id: "op-open-b",
        group_id: "group-b",
        guest_id: "guest-b",
        property_id: "lon-thames"
      )

      run_batch(conn, [payment("op-b", "group-b", 4_000)])

      run_batch(conn, [
        cancel_rooms_operation(["room-b"]) |> Map.put("operation_id", "op-cr")
      ])

      run_batch(conn, [reduce_op("op-reduce", "op-b", 1_000), charge_back_op("op-chb", "op-a")])

      statements =
        for id <- ["op-a", "op-b"], into: %{} do
          {id, statement(conn, id)}
        end

      # Every statement partitions its recorded cash.
      Enum.each(statements, fn {id, statement} ->
        assert disposition_sum(statement) == statement["recorded_cents"],
               "statement #{id} does not partition"
      end)

      recorded = Enum.sum(Enum.map(statements, fn {_, s} -> s["recorded_cents"] end))

      ledger = ledger_json(conn)

      assert ledger["cash_held_cents"] + ledger["cash_refunded_cents"] +
               ledger["cash_retained_cents"] + ledger["cash_converted_to_credit_cents"] +
               ledger["cash_reduced_cents"] + ledger["cash_charged_back_cents"] ==
               recorded
    end
  end

  # -- Helpers ---------------------------------------------------------------

  # Cancels room-b of the default group; used by the agreement test.
  defp cancel_rooms_operation(room_ids) do
    %{
      "type" => "cancel_rooms",
      "occurred_on" => "2026-12-01",
      "group_id" => "group-81",
      "room_ids" => room_ids,
      "refund_method" => "cash"
    }
  end

  # Opens the default group, funds it entirely with hotel credit minted from a
  # 10_000 cash payment on a source group, and charges that payment back.
  defp fund_target_with_credit(conn) do
    assert [%{"status" => "applied"}, _, _] =
             run_batch(conn, [
               open_operation(
                 operation_id: "open-src",
                 group_id: "group-src-op-src",
                 arrival_on: "2027-01-15",
                 departure_on: "2027-01-16",
                 rooms: [%{"room_id" => "room-x", "nightly_rate_cents" => 50_000}]
               ),
               %{
                 "operation_id" => "pay-src",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group-src-op-src",
                 "amount_cents" => 10_000
               },
               %{
                 "operation_id" => "cancel-src",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-16",
                 "group_id" => "group-src-op-src",
                 "refund_method" => "hotel_credit"
               }
             ])

    open_group(conn)

    assert [%{"status" => "applied"}] =
             run_batch(conn, [
               %{
                 "operation_id" => "op-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-10-06",
                 "group_id" => "group-81",
                 "amount_cents" => 11_000
               }
             ])

    :ok
  end

  defp open_group(conn, overrides \\ %{}) do
    assert [%{"status" => "applied"}] = run_batch(conn, [open_operation(overrides)])
    :ok
  end

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn, group_id) do
    %{"data" => group} = conn |> get_group(group_id) |> json_response(200)
    group
  end

  defp ledger_json(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
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

  defp statement(conn, payment_operation_id) do
    %{"data" => data} = conn |> get_payment(payment_operation_id) |> json_response(200)
    data
  end

  defp disposition_sum(statement) do
    statement["held_cents"] + statement["refunded_cents"] + statement["retained_cents"] +
      statement["converted_to_credit_cents"] + statement["reduced_cents"] +
      statement["charged_back_cents"]
  end

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

  defp reduce_op(operation_id, target_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => target_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_op(operation_id, target_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-08",
      "payment_operation_id" => target_id
    }
  end

  defp charge_back(conn, operation_id, target_id) do
    assert [%{"status" => "applied"} = result] =
             run_batch(conn, [charge_back_op(operation_id, target_id)])

    result
  end
end
