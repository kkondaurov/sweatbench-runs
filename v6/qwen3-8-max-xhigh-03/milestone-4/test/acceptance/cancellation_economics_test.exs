defmodule GroupStayWeb.CancellationEconomicsAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of the cancellation economics: a refundable
  cancellation converts cash to hotel credit, the credit funds a later
  group, and the settlement of that group refunds cash and restores the
  credit.
  """

  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group_data(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn, query \\ "") do
    conn |> get("/api/v1/ledger#{query}") |> json_response(200) |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id, query \\ "") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "cash converts to credit, funds a later group, and settles back", %{conn: conn} do
    results =
      submit(conn, [
        %{
          "operation_id" => "op-2001",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "group-91",
          "guest_id" => "guest-31",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25_000}]
        },
        %{
          "operation_id" => "op-2002",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-91",
          "amount_cents" => 5_000
        },
        %{
          "operation_id" => "op-2003",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-20",
          "group_id" => "group-91",
          "refund_method" => "hotel_credit"
        }
      ])

    assert Enum.map(results, & &1["status"]) == ~w(applied applied applied)
    assert Enum.at(results, 2)["refunded_cents"] == 0
    assert Enum.at(results, 2)["retained_cents"] == 0
    assert Enum.at(results, 2)["credit_issued_cents"] == 5_500

    assert guest_credit(conn, "guest-31") == %{
             "guest_id" => "guest-31",
             "available_cents" => 5_500,
             "lots" => [
               %{
                 "source_operation_id" => "op-2003",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-10-21"
               }
             ]
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 5_500,
             "credit_shortfall_cents" => 0
           }

    results =
      submit(conn, [
        %{
          "operation_id" => "op-2004",
          "type" => "open_group",
          "occurred_on" => "2026-10-21",
          "group_id" => "group-92",
          "guest_id" => "guest-31",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 25_000}]
        },
        %{
          "operation_id" => "op-2005",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-22",
          "group_id" => "group-92",
          "amount_cents" => 5_500
        },
        %{
          "operation_id" => "op-2006",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-22",
          "group_id" => "group-92",
          "amount_cents" => 2_000
        }
      ])

    assert Enum.map(results, & &1["status"]) == ~w(applied applied applied)
    assert Enum.at(results, 1)["outstanding_deposit_cents"] == 9_500
    assert Enum.at(results, 1)["revision"] == 2

    funded = group_data(conn, "group-92")
    assert funded["deposit_paid_cents"] == 7_500
    assert funded["cash_paid_cents"] == 2_000
    assert funded["credit_paid_cents"] == 5_500
    assert funded["outstanding_deposit_cents"] == 7_500

    assert guest_credit(conn, "guest-31")["available_cents"] == 0
    assert ledger(conn)["cash_held_cents"] == 2_000
    assert ledger(conn)["credit_liability_cents"] == 5_500

    assert [settlement] =
             submit(conn, [
               %{
                 "operation_id" => "op-2007",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "group-92"
               }
             ])

    assert settlement["refunded_cents"] == 2_000
    assert settlement["retained_cents"] == 0
    assert settlement["credit_issued_cents"] == 0

    assert guest_credit(conn, "guest-31") == %{
             "guest_id" => "guest-31",
             "available_cents" => 5_500,
             "lots" => [
               %{
                 "source_operation_id" => "op-2003",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-10-21"
               }
             ]
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 2_000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 5_500,
             "credit_shortfall_cents" => 0
           }

    assert ledger(conn, "?on=2027-10-21")["credit_liability_cents"] == 0
    assert guest_credit(conn, "guest-31", "?on=2027-10-21")["available_cents"] == 0
  end
end
