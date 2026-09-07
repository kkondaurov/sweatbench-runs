defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  describe "transfer_deposit" do
    test "moves newest funding first across kinds and preserves its provenance", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 open_group("credit-seed", "guest", 1),
                 payment("seed-pay", "credit-seed", 1_000, 1),
                 cancel_for_credit("seed-cancel", "credit-seed", 2),
                 open_group("source", "guest", 2),
                 payment("source-pay", "source", 1_000, 1),
                 apply_credit("source-credit", "source", 1_000, 2),
                 open_group("destination", "guest", 2),
                 transfer("move", "source", "destination", 1_500, 3, 1)
               ])

      result = List.last(results)

      assert result == %{
               "operation_id" => "move",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 1_500,
               "source_outstanding_deposit_cents" => 1_500,
               "destination_outstanding_deposit_cents" => 500,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert room_funding("source") == [
               %{"room_id" => "room-1", "cash_paid_cents" => 500, "credit_paid_cents" => 0},
               %{"room_id" => "room-2", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
             ]

      assert room_funding("destination") == [
               %{"room_id" => "room-1", "cash_paid_cents" => 0, "credit_paid_cents" => 1_000},
               %{"room_id" => "room-2", "cash_paid_cents" => 500, "credit_paid_cents" => 0}
             ]

      assert get_json("/api/v1/payments/source-pay")["data"]["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 500},
               %{"group_id" => "source", "amount_cents" => 500}
             ]

      ledger = get_json("/api/v1/ledger?on=2026-10-10")["data"]
      assert ledger["cash_held_cents"] == 1_000
      assert ledger["cash_converted_to_credit_cents"] == 1_000
      assert ledger["credit_liability_cents"] == 1_100

      assert %{"results" => [cancelled]} =
               submit(build_conn(), [cancel_group("cancel-destination", "destination", 2)])

      assert cancelled["refunded_cents"] == 500
      assert cancelled["credit_issued_cents"] == 0

      assert get_json("/api/v1/guests/guest/credit?on=2026-10-10")["data"][
               "available_cents"
             ] == 1_100

      statement = get_json("/api/v1/payments/source-pay")["data"]
      assert statement["held_cents"] == 500
      assert statement["refunded_cents"] == 500
      assert statement["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 500}]
    end

    test "is durably idempotent and validates existence and revisions in documented order", %{
      conn: conn
    } do
      missing = transfer("missing", "absent-source", "absent-destination", -1, 9, 9)

      assert %{
               "results" => [
                 %{
                   "code" => "group_not_found",
                   "group_id" => "absent-source"
                 }
               ]
             } = submit(conn, [missing])

      assert %{"results" => [_, missing_destination]} =
               submit(build_conn(), [
                 open_group("only-source", "guest", 1),
                 transfer("missing-destination", "only-source", "absent", 1, 1, 1)
               ])

      assert missing_destination["code"] == "group_not_found"
      assert missing_destination["group_id"] == "absent"

      move = transfer("move", "source", "destination", 500, 2, 99)

      assert %{"results" => [_, _, _, stale]} =
               submit(build_conn(), [
                 open_group("source", "guest", 1),
                 payment("pay", "source", 500, 1),
                 open_group("destination", "guest", 1),
                 move
               ])

      assert stale == %{
               "operation_id" => "move",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      corrected = %{move | "destination_expected_revision" => 1, "operation_id" => "move-ok"}
      assert %{"results" => [applied]} = submit(build_conn(), [corrected])
      assert applied["status"] == "applied"

      assert %{"results" => [replayed]} = submit(build_conn(), [corrected])
      assert replayed == applied
      assert get_json("/api/v1/groups/source")["data"]["revision"] == 3
      assert get_json("/api/v1/groups/destination")["data"]["revision"] == 2
    end

    test "rejects transfer rules atomically and identifies the inactive group", %{conn: conn} do
      assert %{"results" => [_, _, _, _, _, invalid_pair, invalid_amount, too_much_held]} =
               submit(conn, [
                 open_group("source", "guest", 1),
                 payment("pay", "source", 500, 1),
                 open_group("destination", "guest", 1),
                 open_group("other-guest", "other", 1),
                 open_group("empty", "guest", 1),
                 transfer("different-guests", "source", "other-guest", 100, 2, 1),
                 transfer("zero", "source", "destination", 0, 2, 1),
                 transfer("too-much", "source", "destination", 501, 2, 1)
               ])

      assert invalid_pair["code"] == "invalid_transfer"
      assert invalid_amount["code"] == "invalid_amount"
      assert too_much_held["code"] == "transfer_exceeds_held_funding"

      assert %{"results" => [_, outstanding]} =
               submit(build_conn(), [
                 payment("destination-payment", "destination", 900, 1),
                 transfer("too-full", "source", "destination", 200, 2, 2)
               ])

      assert outstanding["code"] == "transfer_exceeds_outstanding"

      cancel = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "destination",
        "expected_revision" => 2
      }

      inactive_transfer = transfer("inactive", "source", "destination", 100, 2, 3)

      assert %{"results" => [_, rejected]} = submit(build_conn(), [cancel, inactive_transfer])
      assert rejected["code"] == "group_not_active"
      assert rejected["group_id"] == "destination"

      assert get_json("/api/v1/groups/source")["data"]["deposit_paid_cents"] == 500
    end

    test "reductions and chargebacks follow transferred cash and revise every changed group", %{
      conn: conn
    } do
      assert %{"results" => [_, _, _, _, reduction]} =
               submit(conn, [
                 open_group("source", "guest", 1),
                 payment("pay", "source", 1_000, 1),
                 open_group("destination", "guest", 1),
                 transfer("move", "source", "destination", 600, 2, 1),
                 reduction("reduce", "pay", 700, 3)
               ])

      assert reduction["revision"] == 4
      assert reduction["outstanding_deposit_cents"] == 700
      assert get_json("/api/v1/groups/destination")["data"]["revision"] == 3

      statement = get_json("/api/v1/payments/pay")["data"]
      assert statement["held_cents"] == 300
      assert statement["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 300}]

      # A fresh payment is transferred and settled on the destination. Its chargeback must remove
      # the destination's refund classification while still returning the source revision.
      assert %{"results" => [_, transferred, rejected_zero, cancelled, charged]} =
               submit(build_conn(), [
                 payment("pay-settled", "source", 700, 4),
                 transfer("move-settled", "source", "destination", 700, 5, 3),
                 transfer("move-held-aside", "source", "destination", 0, 6, 4),
                 cancel_group("cancel-destination", "destination", 4),
                 chargeback("chargeback", "pay-settled", 6)
               ])

      assert transferred["status"] == "applied"
      assert rejected_zero["status"] == "rejected"
      assert rejected_zero["code"] == "invalid_amount"
      assert cancelled["status"] == "applied"
      assert charged["charged_back_cents"] == 700
      assert charged["revision"] == 7
      assert get_json("/api/v1/groups/destination")["data"]["revision"] == 6

      ledger = get_json("/api/v1/ledger")["data"]
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 700
      assert get_json("/api/v1/payments/pay-settled")["data"]["held_by_group"] == []
    end
  end

  defp open_group(group_id, guest_id, room_count) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.map(1..room_count, fn position ->
          %{"room_id" => "room-#{position}", "nightly_rate_cents" => 5_000}
        end)
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

  defp apply_credit(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-08",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancel_for_credit(operation_id, group_id, revision) do
    cancel_group(operation_id, group_id, revision)
    |> Map.put("refund_method", "hotel_credit")
  end

  defp cancel_group(operation_id, group_id, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-10",
      "group_id" => group_id,
      "expected_revision" => revision
    }
  end

  defp transfer(operation_id, source, destination, amount, source_revision, destination_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-09",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision
    }
  end

  defp reduction(operation_id, payment_operation_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-11",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp chargeback(operation_id, payment_operation_id, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-12",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => revision
    }
  end

  defp room_funding(group_id) do
    get_json("/api/v1/groups/#{group_id}")["data"]["rooms"]
    |> Enum.map(&Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"]))
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp get_json(path), do: build_conn() |> get(path) |> json_response(200)
end
