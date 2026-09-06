defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  defp open_group(conn, group_id, rate_plan) do
    post(conn, "/api/v1/partner-batches", %{
      "operations" => [
        %{
          "operation_id" => "op-open-#{group_id}",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => group_id,
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => rate_plan,
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }
      ]
    })
  end

  defp pay(conn, group_id, amount_cents, op_id \\ "op-pay") do
    post(conn, "/api/v1/partner-batches", %{
      "operations" => [
        %{
          "operation_id" => op_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ]
    })
  end

  defp cancel(conn, group_id, occurred_on, op_id \\ "op-cancel") do
    post(conn, "/api/v1/partner-batches", %{
      "operations" => [
        %{
          "operation_id" => op_id,
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id
        }
      ]
    })
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  describe "GET /api/v1/ledger" do
    test "starts empty", %{conn: conn} do
      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "unpaid deposit requirements are not cash", %{conn: conn} do
      open_group(conn, "group-81", "flexible")

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "records cash held on active reservations", %{conn: conn} do
      open_group(conn, "group-81", "flexible")
      pay(conn, "group-81", 5_000)

      data = ledger(conn)
      assert data["cash_held_cents"] == 5_000
      assert data["cash_refunded_cents"] == 0
      assert data["cash_retained_cents"] == 0
    end

    test "moves held cash to refunded on a refundable cancellation", %{conn: conn} do
      open_group(conn, "group-81", "flexible")
      pay(conn, "group-81", 5_000)
      cancel(conn, "group-81", "2026-11-01")

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "moves held cash to retained on a non-refundable cancellation", %{conn: conn} do
      open_group(conn, "group-adv", "advance_purchase")
      pay(conn, "group-adv", 30_000)
      cancel(conn, "group-adv", "2026-11-01")

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 30_000,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "aggregates across groups", %{conn: conn} do
      open_group(conn, "group-81", "flexible")
      open_group(conn, "group-82", "flexible")
      pay(conn, "group-81", 5_000)
      pay(conn, "group-82", 2_000, "op-pay-2")

      # group-82 cancels 9 days before arrival: retained.
      cancel(conn, "group-82", "2026-12-01")

      assert ledger(conn) == %{
               "cash_held_cents" => 5_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 2_000,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "rejected payments do not move money", %{conn: conn} do
      open_group(conn, "group-81", "flexible")

      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "op-p",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 9_999_999
          }
        ]
      })

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end
  end
end
