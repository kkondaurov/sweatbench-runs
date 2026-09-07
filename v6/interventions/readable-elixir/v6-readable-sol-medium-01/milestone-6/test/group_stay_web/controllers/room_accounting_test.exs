defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  describe "room accounting and payment corrections" do
    test "funds rooms in order and settles selected rooms in original order", %{conn: conn} do
      operations = [
        open("group", "guest", [1_000, 2_000]),
        cash("pay", "group", 2_500, 1),
        %{
          "operation_id" => "cancel-room",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-05",
          "group_id" => "group",
          "room_ids" => ["room-2"],
          "expected_revision" => 2
        }
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, _, cancellation]} = json_response(conn, 200)
      assert cancellation["cancelled_room_ids"] == ["room-2"]
      assert cancellation["refunded_cents"] == 1_500

      group = get_data(conn, "/api/v1/groups/group")
      assert group["status"] == "active"
      assert group["deposit_due_cents"] == 1_000
      assert group["deposit_paid_cents"] == 1_000

      assert [first, second] = group["rooms"]

      assert Map.take(first, [
               "status",
               "lodging_total_cents",
               "deposit_due_cents",
               "cash_paid_cents"
             ]) == %{
               "status" => "active",
               "lodging_total_cents" => 5_000,
               "deposit_due_cents" => 1_000,
               "cash_paid_cents" => 1_000
             }

      assert Map.take(second, [
               "status",
               "lodging_total_cents",
               "deposit_due_cents",
               "cash_paid_cents"
             ]) == %{
               "status" => "cancelled",
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "cash_paid_cents" => 0
             }

      payment = get_data(conn, "/api/v1/payments/pay")
      assert payment["recorded_cents"] == 2_500
      assert payment["held_cents"] == 1_000
      assert payment["refunded_cents"] == 1_500
    end

    test "reduces only the target payment in reverse fill order and replays durably", %{
      conn: conn
    } do
      reduction = %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 600,
        "expected_revision" => 3
      }

      operations = [
        open("group", "guest", [1_000, 2_000]),
        cash("pay-1", "group", 2_500, 1),
        cash("pay-2", "group", 500, 2),
        reduction,
        reduction
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, _, _, reduced, replay]} = json_response(conn, 200)
      assert reduced == replay
      assert reduced["outstanding_deposit_cents"] == 600
      assert reduced["revision"] == 4

      assert %{"rooms" => [first, second]} = get_data(conn, "/api/v1/groups/group")
      assert first["cash_paid_cents"] == 1_000
      assert second["cash_paid_cents"] == 1_400

      assert %{
               "recorded_cents" => 2_500,
               "held_cents" => 1_900,
               "reduced_cents" => 600,
               "charged_back_cents" => 0
             } = get_data(conn, "/api/v1/payments/pay-1")

      ledger = get_data(conn, "/api/v1/ledger")
      assert ledger["cash_held_cents"] == 2_400
      assert ledger["cash_reduced_cents"] == 600
    end

    test "charges back converted cash, reports shortfall, and absorbs restored credit", %{
      conn: conn
    } do
      operations = [
        open("source", "guest", [2_000]),
        cash("pay-1", "source", 1_000, 1),
        cash("pay-2", "source", 1_000, 2),
        cancel("convert", "source", 3, "hotel_credit"),
        open("target", "guest", [2_000]),
        credit("spend", "target", 1_500, 1),
        %{
          "operation_id" => "chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-07",
          "payment_operation_id" => "pay-1",
          "expected_revision" => 4
        }
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 6)["charged_back_cents"] == 1_000
      assert Enum.at(results, 6)["revision"] == 5
      assert get_data(conn, "/api/v1/groups/target")["revision"] == 2

      ledger = get_data(conn, "/api/v1/ledger?on=2026-10-07")
      assert ledger["cash_converted_to_credit_cents"] == 1_000
      assert ledger["cash_charged_back_cents"] == 1_000
      assert ledger["credit_liability_cents"] == 1_500
      assert ledger["credit_shortfall_cents"] == 400

      conn =
        post(recycle(conn), ~p"/api/v1/partner-batches", %{
          operations: [cancel("restore", "target", 2, "cash")]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
      ledger = get_data(conn, "/api/v1/ledger?on=2026-10-08")
      assert ledger["credit_liability_cents"] == 1_100
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "uses the documented reconciliation errors", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{operations: [open("group", "guest", [1_000])]})

      assert response(conn, 200)

      assert get(recycle(conn), "/api/v1/payments/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert get(recycle(conn), "/api/v1/payments/open-group") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  defp open(group_id, guest_id, deposits) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => "flexible",
      "rooms" =>
        deposits
        |> Enum.with_index(1)
        |> Enum.map(fn {deposit, position} ->
          %{"room_id" => "room-#{position}", "nightly_rate_cents" => deposit * 5}
        end)
    }
  end

  defp cash(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp credit(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancel(operation_id, group_id, revision, method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => if(operation_id == "restore", do: "2026-10-08", else: "2026-10-04"),
      "group_id" => group_id,
      "refund_method" => method,
      "expected_revision" => revision
    }
  end

  defp get_data(conn, path) do
    get(recycle(conn), path) |> json_response(200) |> Map.fetch!("data")
  end
end
