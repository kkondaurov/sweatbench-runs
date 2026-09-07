defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  describe "room-level funding and cancellation" do
    test "fills rooms in order and settles selected rooms in original order", %{conn: conn} do
      operations = [
        open_group("group", "guest", three_equal_rooms()),
        cash_payment("pay", "group", 1_200),
        %{
          "operation_id" => "cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-05",
          "group_id" => "group",
          "room_ids" => ["room-b", "room-a"],
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ]

      assert %{"results" => [_opened, _paid, cancelled]} = submit(conn, operations)

      assert cancelled == %{
               "operation_id" => "cancel-rooms",
               "status" => "applied",
               "group_id" => "group",
               "cancelled_room_ids" => ["room-a", "room-b"],
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_320,
               "revision" => 3
             }

      group = fetch_group(conn, "group")

      assert %{
               "status" => "active",
               "lodging_total_cents" => 3_000,
               "deposit_due_cents" => 600,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 600
             } = group

      assert Enum.map(group["rooms"], &Map.take(&1, ["room_id", "status", "cash_paid_cents"])) ==
               [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-c", "status" => "active", "cash_paid_cents" => 0}
               ]

      assert fetch_credit(conn, "guest")["available_cents"] == 1_320
    end

    test "interleaves cash and credit operations in room-fill order", %{conn: conn} do
      submit(conn, [
        open_group("source", "guest"),
        cash_payment("source-pay", "source", 600),
        cancellation("source-cancel", "source", "hotel_credit"),
        open_group("group", "guest", three_equal_rooms()),
        apply_credit("credit", "group", 300),
        cash_payment("cash", "group", 600)
      ])

      rooms = fetch_group(conn, "group")["rooms"]

      assert Enum.map(rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
               {300, 300},
               {300, 0},
               {0, 0}
             ]
    end

    test "rejects duplicate, missing, and already-cancelled room identifiers atomically", %{
      conn: conn
    } do
      submit(conn, [open_group("group", "guest", three_equal_rooms())])

      duplicate = cancel_rooms("duplicate", ["room-a", "room-a"])
      missing = cancel_rooms("missing", ["room-a", "not-here"])
      valid = cancel_rooms("valid", ["room-a"])
      again = cancel_rooms("again", ["room-a"])

      assert %{"results" => [duplicate_result, missing_result, valid_result, again_result]} =
               submit(conn, [duplicate, missing, valid, again])

      assert duplicate_result["code"] == "invalid_rooms"
      assert missing_result["code"] == "invalid_rooms"
      assert valid_result["revision"] == 2
      assert again_result["code"] == "invalid_rooms"
      assert fetch_group(conn, "group")["revision"] == 2
    end
  end

  describe "cash payment reductions" do
    test "removes allocations in reverse fill order and reconciles every cent", %{conn: conn} do
      opening = open_group("group", "guest")
      payment = cash_payment("pay", "group", 10_000)
      reduction = reduce_payment("reduce", "pay", 1_500, 2)

      assert %{"results" => [_opened, _paid, reduced]} =
               submit(conn, [opening, payment, reduction])

      assert reduced == %{
               "operation_id" => "reduce",
               "status" => "applied",
               "payment_operation_id" => "pay",
               "group_id" => "group",
               "amount_cents" => 1_500,
               "outstanding_deposit_cents" => 11_000,
               "revision" => 3
             }

      assert Enum.map(fetch_group(conn, "group")["rooms"], & &1["cash_paid_cents"]) == [
               8_500,
               0
             ]

      assert fetch_payment(conn, "pay") == %{
               "payment_operation_id" => "pay",
               "original_group_id" => "group",
               "recorded_cents" => 10_000,
               "held_cents" => 8_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_500,
               "charged_back_cents" => 0
             }

      assert %{"results" => [replayed]} = submit(conn, [reduction])
      assert replayed == reduced

      assert %{"results" => [finished]} =
               submit(conn, [reduce_payment("reduce-rest", "pay", 8_500, 3)])

      assert finished["status"] == "applied"
      assert fetch_payment(conn, "pay")["reduced_cents"] == 10_000

      assert %{"results" => [rejected]} =
               submit(conn, [reduce_payment("reduce-again", "pay", 1, 4)])

      assert rejected["code"] == "payment_not_reducible"
      assert ledger(conn)["cash_reduced_cents"] == 10_000
    end

    test "uses the documented target and amount rejection codes", %{conn: conn} do
      submit(conn, [open_group("group", "guest"), cash_payment("pay", "group", 1_000)])

      operations = [
        reduce_payment("unknown", "not-found", 1),
        reduce_payment("not-payment", "open-group", 1),
        reduce_payment("invalid", "pay", 0),
        reduce_payment("excess", "pay", 1_001)
      ]

      assert %{"results" => results} = submit(conn, operations)

      assert Enum.map(results, & &1["code"]) == [
               "operation_not_found",
               "payment_not_reducible",
               "invalid_amount",
               "reduction_exceeds_held_cash"
             ]
    end
  end

  describe "chargebacks and credit clawback" do
    test "reclassifies converted principal and tracks applied-credit shortfall until restoration",
         %{conn: conn} do
      operations = [
        open_group("source", "guest"),
        cash_payment("source-pay", "source", 1_005),
        cancellation("source-cancel", "source", "hotel_credit"),
        open_group("target", "guest"),
        apply_credit("target-credit", "target", 1_106)
      ]

      assert %{"results" => results} = submit(conn, operations)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      chargeback = %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "source-pay",
        "expected_revision" => 3
      }

      assert %{"results" => [charged_back]} = submit(conn, [chargeback])

      assert charged_back == %{
               "operation_id" => "chargeback",
               "status" => "applied",
               "payment_operation_id" => "source-pay",
               "group_id" => "source",
               "charged_back_cents" => 1_005,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      totals = ledger(conn)
      assert totals["cash_converted_to_credit_cents"] == 0
      assert totals["cash_charged_back_cents"] == 1_005
      assert totals["credit_liability_cents"] == 1_106
      assert totals["credit_shortfall_cents"] == 1_106

      assert fetch_payment(conn, "source-pay")["charged_back_cents"] == 1_005
      assert fetch_credit(conn, "guest")["available_cents"] == 0

      assert %{"results" => [cancelled]} =
               submit(conn, [cancellation("target-cancel", "target")])

      assert cancelled["status"] == "applied"
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "assigns a shared lot's rounded bonus through telescoping funding totals", %{conn: conn} do
      submit(conn, [
        open_group("source", "guest"),
        cash_payment("first-pay", "source", 3),
        cash_payment("second-pay", "source", 3),
        cancellation("source-cancel", "source", "hotel_credit")
      ])

      assert fetch_credit(conn, "guest")["available_cents"] == 7

      first_chargeback = %{
        "operation_id" => "first-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "first-pay",
        "expected_revision" => 4
      }

      second_chargeback = %{
        "operation_id" => "second-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "second-pay",
        "expected_revision" => 5
      }

      assert %{"results" => [first]} = submit(conn, [first_chargeback])
      assert first["charged_back_cents"] == 3
      assert fetch_credit(conn, "guest")["available_cents"] == 4

      assert %{"results" => [second]} = submit(conn, [second_chargeback])
      assert second["charged_back_cents"] == 3
      assert fetch_credit(conn, "guest")["available_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 6
    end

    test "payment reads distinguish missing and non-reconcilable operations", %{conn: conn} do
      submit(conn, [open_group("group", "guest")])

      assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert conn |> get("/api/v1/payments/open-group") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  defp open_group(group_id, guest_id, rooms \\ nil) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" =>
        rooms ||
          [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
    }
  end

  defp three_equal_rooms do
    Enum.map(~w(room-a room-b room-c), fn room_id ->
      %{"room_id" => room_id, "nightly_rate_cents" => 1_000}
    end)
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_payment(operation_id, payment_operation_id, amount_cents, revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put_revision(revision)
  end

  defp cancel_rooms(operation_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-05",
      "group_id" => "group",
      "room_ids" => room_ids
    }
  end

  defp cancellation(operation_id, group_id, refund_method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id
    }
    |> then(fn operation ->
      if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
    end)
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp fetch_group(conn, group_id) do
    %{"data" => group} = conn |> get("/api/v1/groups/#{group_id}") |> json_response(200)
    group
  end

  defp fetch_payment(conn, operation_id) do
    %{"data" => payment} =
      conn |> get("/api/v1/payments/#{operation_id}") |> json_response(200)

    payment
  end

  defp fetch_credit(conn, guest_id) do
    %{"data" => credit} =
      conn
      |> get("/api/v1/guests/#{guest_id}/credit?on=2026-10-07")
      |> json_response(200)

    credit
  end

  defp ledger(conn) do
    %{"data" => totals} =
      conn |> get("/api/v1/ledger?on=2026-10-07") |> json_response(200)

    totals
  end

  defp maybe_put_revision(operation, nil), do: operation

  defp maybe_put_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)
end
