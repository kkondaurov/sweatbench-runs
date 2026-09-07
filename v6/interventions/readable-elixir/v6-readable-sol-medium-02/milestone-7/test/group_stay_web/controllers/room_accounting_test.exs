defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  describe "room funding and selected-room settlement" do
    test "allocates funding forward and reduces one payment in reverse fill order", %{conn: conn} do
      operations = [
        open_operation("group", 10_000),
        payment("pay-1", "group", 2_500, 1),
        payment("pay-2", "group", 1_000, 2),
        reduction("reduce-1", "pay-1", 600, 3)
      ]

      assert %{"results" => [_, _, _, result]} = submit(conn, operations)

      assert result == %{
               "operation_id" => "reduce-1",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group",
               "amount_cents" => 600,
               "outstanding_deposit_cents" => 1_100,
               "revision" => 4
             }

      assert %{"data" => group} = get_json("/api/v1/groups/group")

      assert Enum.map(group["rooms"], &Map.take(&1, ["room_id", "cash_paid_cents"])) == [
               %{"room_id" => "room-a", "cash_paid_cents" => 1_900},
               %{"room_id" => "room-b", "cash_paid_cents" => 1_000}
             ]

      assert %{"data" => statement} = get_json("/api/v1/payments/pay-1")
      assert statement["recorded_cents"] == 2_500
      assert statement["held_cents"] == 1_900
      assert statement["reduced_cents"] == 600

      assert get_json("/api/v1/ledger")["data"]["cash_reduced_cents"] == 600
    end

    test "cancels rooms in group order and computes one combined credit bonus", %{conn: conn} do
      cancellation = %{
        "operation_id" => "cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-10",
        "group_id" => "group",
        "room_ids" => ["room-b", "room-a"],
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }

      assert %{"results" => [_, _, result]} =
               submit(conn, [
                 open_operation("group", 10_000),
                 payment("pay", "group", 3_001, 1),
                 cancellation
               ])

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
      assert result["credit_issued_cents"] == 3_301
      assert result["refunded_cents"] == 0
      assert get_json("/api/v1/groups/group")["data"]["status"] == "cancelled"

      assert get_json("/api/v1/guests/guest/credit?on=2026-10-10")["data"][
               "available_cents"
             ] == 3_301
    end

    test "rejects the whole room cancellation when any room is invalid", %{conn: conn} do
      invalid = %{
        "operation_id" => "cancel-invalid",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-10",
        "group_id" => "group",
        "room_ids" => ["room-a", "missing"],
        "expected_revision" => 2
      }

      assert %{"results" => [_, _, %{"code" => "invalid_rooms"}]} =
               submit(conn, [
                 open_operation("group", 10_000),
                 payment("pay", "group", 1_000, 1),
                 invalid
               ])

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
               get_json("/api/v1/groups/group")
    end

    test "full cancellation later settles only rooms that are still active", %{conn: conn} do
      cancel_first = %{
        "operation_id" => "cancel-first",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-10",
        "group_id" => "group",
        "room_ids" => ["room-a"],
        "expected_revision" => 2
      }

      cancel_rest = %{
        "operation_id" => "cancel-rest",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "group",
        "expected_revision" => 4
      }

      assert %{"results" => [_, _, first, _, rest]} =
               submit(conn, [
                 open_operation("group", 10_000),
                 payment("pay-1", "group", 2_500, 1),
                 cancel_first,
                 payment("pay-2", "group", 1_000, 3),
                 cancel_rest
               ])

      assert first["refunded_cents"] == 2_000
      assert rest["retained_cents"] == 1_500

      assert %{
               "data" => %{
                 "lodging_total_cents" => 0,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "status" => "cancelled"
               }
             } = get_json("/api/v1/groups/group")

      ledger = get_json("/api/v1/ledger")["data"]
      assert ledger["cash_refunded_cents"] == 2_000
      assert ledger["cash_retained_cents"] == 1_500
    end
  end

  describe "payment chargebacks and reconciliation" do
    test "charges back converted cash and tracks then absorbs credit shortfall", %{conn: conn} do
      source = open_operation("source", 5_000, one_room: true)

      convert = %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }

      destination = open_operation("destination", 5_500, one_room: true)

      apply_credit = %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-12",
        "group_id" => "destination",
        "amount_cents" => 1_100,
        "expected_revision" => 1
      }

      assert %{"results" => results} =
               submit(conn, [
                 source,
                 payment("pay", "source", 1_000, 1),
                 convert,
                 destination,
                 apply_credit
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      chargeback = %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-13",
        "payment_operation_id" => "pay",
        "expected_revision" => 3
      }

      assert %{"results" => [%{"charged_back_cents" => 1_000, "revision" => 4}]} =
               submit(build_conn(), [chargeback])

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 1_000,
                 "credit_liability_cents" => 1_100,
                 "credit_shortfall_cents" => 1_100
               }
             } = get_json("/api/v1/ledger?on=2026-10-13")

      assert %{
               "data" => %{
                 "recorded_cents" => 1_000,
                 "converted_to_credit_cents" => 0,
                 "charged_back_cents" => 1_000
               }
             } = get_json("/api/v1/payments/pay")

      cancel_destination = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-14",
        "group_id" => "destination",
        "expected_revision" => 2
      }

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(build_conn(), [cancel_destination])

      ledger = get_json("/api/v1/ledger?on=2026-10-14")["data"]
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "uses the documented missing and non-payment errors", %{conn: conn} do
      assert %{"error" => %{"code" => "operation_not_found"}} =
               conn |> get("/api/v1/payments/missing") |> json_response(404)

      submit(build_conn(), [open_operation("group", 5_000, one_room: true)])

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
               build_conn() |> get("/api/v1/payments/open-group") |> json_response(422)

      missing_reduction = reduction("reduce-missing", "missing", 10, nil)
      non_payment_reduction = reduction("reduce-open", "open-group", 10, nil)

      assert %{"results" => [missing, non_payment]} =
               submit(build_conn(), [missing_reduction, non_payment_reduction])

      assert missing["code"] == "operation_not_found"
      assert non_payment["code"] == "payment_not_reducible"
    end

    test "composes reductions, permits the full remainder, and replays exactly", %{conn: conn} do
      first = reduction("reduce-first", "pay", 400, 2)
      final = reduction("reduce-final", "pay", 600, 3)

      assert %{"results" => [_, _, first_result, final_result]} =
               submit(conn, [
                 open_operation("group", 5_000, one_room: true),
                 payment("pay", "group", 1_000, 1),
                 first,
                 final
               ])

      assert first_result["outstanding_deposit_cents"] == 400
      assert final_result["outstanding_deposit_cents"] == 1_000

      assert %{"results" => [^final_result]} = submit(build_conn(), [final])

      unavailable = reduction("reduce-again", "pay", 1, 4)

      chargeback = %{
        "operation_id" => "chargeback-reduced",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "pay",
        "expected_revision" => 4
      }

      assert %{"results" => [cannot_reduce, cannot_charge]} =
               submit(build_conn(), [unavailable, chargeback])

      assert cannot_reduce["code"] == "payment_not_reducible"
      assert cannot_charge["code"] == "payment_not_chargeable"
      assert get_json("/api/v1/groups/group")["data"]["revision"] == 4
    end
  end

  defp open_operation(group_id, rate, options \\ []) do
    rooms =
      if options[:one_room] do
        [%{"room_id" => "room-a", "nightly_rate_cents" => rate}]
      else
        [
          %{"room_id" => "room-a", "nightly_rate_cents" => rate},
          %{"room_id" => "room-b", "nightly_rate_cents" => rate}
        ]
      end

    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => rooms
    }
  end

  defp payment(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp reduction(operation_id, payment_operation_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
    |> then(fn operation ->
      if revision, do: Map.put(operation, "expected_revision", revision), else: operation
    end)
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp get_json(path), do: build_conn() |> get(path) |> json_response(200)
end
