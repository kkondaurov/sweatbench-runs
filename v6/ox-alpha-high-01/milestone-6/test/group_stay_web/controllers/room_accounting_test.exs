defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  alias GroupStay.Groups.OperationRecord
  alias GroupStay.Repo

  # The default group has rooms room-a (15_000/night) and room-b (17_500/night)
  # for three nights: lodging 45_000 and 52_500, deposits 9_000 and 10_500.

  describe "room-level accounting" do
    test "cash fills active room deposits in the rooms' original order", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      group = group_json(conn, "group-81")

      assert [
               %{
                 "room_id" => "room-a",
                 "status" => "active",
                 "lodging_cents" => 45_000,
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 9_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "status" => "active",
                 "lodging_cents" => 52_500,
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 3_000,
                 "credit_paid_cents" => 0
               }
             ] = group["rooms"]

      assert group["deposit_paid_cents"] == 12_000
      assert group["outstanding_deposit_cents"] == 7_500
    end

    test "hotel credit funds deposits after cash, in the same room order", %{conn: conn} do
      issue_credit(conn, "op-src", 10_000)
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 8_000), credit_operation("op-credit", 4_000)])

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 8_000, "credit_paid_cents" => 1_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 3_000}
             ] = group_json(conn, "group-81")["rooms"]
    end

    test "funding from before durable records becomes one unattributed senior block", %{
      conn: conn
    } do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay-old", 5_000)])

      # Simulate a database from before durable operation records existed.
      Repo.delete_all(OperationRecord)
      GroupStay.Groups.Backfill.run()

      # Legacy funding cannot be targeted or reconciled.
      results = run_batch(conn, [reduce_payment("op-reduce-legacy", "op-pay-old", 1)])

      assert [%{"status" => "rejected", "code" => "operation_not_found"}] = results

      assert get_payment(conn, "op-pay-old") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      # New durable funding allocates behind the senior block, and aggregate
      # balances were not changed by creating allocations.
      run_batch(conn, [payment_operation("op-pay-new", 7_000)])

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 3_000}
             ] = group_json(conn, "group-81")["rooms"]

      statement = statement(conn, "op-pay-new")
      assert statement["held_cents"] == 7_000
      assert disposition_sum(statement) == statement["recorded_cents"]

      ledger = ledger_json(conn)
      assert ledger["cash_held_cents"] == 12_000
    end

    test "rebuilding a cancelled group's history preserves payment dispositions", %{conn: conn} do
      issue_credit(conn, "op-src", 5_555)

      # Rebuild all projections from the durable records; nothing moves.
      GroupStay.Groups.Backfill.run()

      statement = statement(conn, "pay-op-src")

      assert statement["held_cents"] == 0
      assert statement["converted_to_credit_cents"] == 5_555
      assert disposition_sum(statement) == 5_555

      # The rebuilt entitlement claws back from the issued lot exactly.
      result = charge_back(conn, "op-chb", "pay-op-src")

      assert result["charged_back_cents"] == 5_555
      assert lots(conn) == []
    end
  end

  # -- Helpers ---------------------------------------------------------------

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

  # Opens a source group for guest-22, funds it fully with cash, and cancels it
  # refundably with hotel credit so guest-22 holds a lot worth 110% of the cash.
  defp issue_credit(conn, operation_id, cash_cents, cancelled_on \\ "2026-11-16") do
    group_id = "group-src-" <> operation_id
    arrival_on = Date.to_iso8601(Date.add(Date.from_iso8601!(cancelled_on), 60))

    assert [%{"status" => "applied"}, _, _] =
             run_batch(conn, [
               open_operation(
                 operation_id: "open-" <> operation_id,
                 group_id: group_id,
                 arrival_on: arrival_on,
                 departure_on: Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 1)),
                 rooms: [%{"room_id" => "room-x", "nightly_rate_cents" => cash_cents * 5}]
               ),
               %{
                 "operation_id" => "pay-" <> operation_id,
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "group_id" => group_id,
                 "amount_cents" => cash_cents
               },
               %{
                 "operation_id" => "cancel-" <> operation_id,
                 "type" => "cancel_group",
                 "occurred_on" => cancelled_on,
                 "group_id" => group_id,
                 "refund_method" => "hotel_credit"
               }
             ])

    :ok
  end

  defp payment_operation(operation_id, amount_cents),
    do: %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }

  defp credit_operation(operation_id, amount_cents),
    do: %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }

  defp reduce_payment(operation_id, target_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => target_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back(conn, operation_id, target_id) do
    assert [%{"status" => "applied"} = result] =
             run_batch(conn, [
               %{
                 "operation_id" => operation_id,
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-08",
                 "payment_operation_id" => target_id
               }
             ])

    result
  end
end
