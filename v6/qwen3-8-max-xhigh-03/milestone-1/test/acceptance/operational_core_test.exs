defmodule GroupStayWeb.OperationalCoreAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of the operational core: a partner batch opens
  groups, funds and moves them, and cancels them, while the read endpoints
  report the resulting state.
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

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  test "a partner batch drives the full group lifecycle", %{conn: conn} do
    results =
      submit(conn, [
        %{
          "operation_id" => "op-1001",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "group-81",
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        },
        %{
          "operation_id" => "op-1002",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "group-82",
          "guest_id" => "guest-23",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-12",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
        },
        %{
          "operation_id" => "op-1003",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "amount_cents" => 10_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "op-1004",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-12",
          "expected_revision" => 2
        }
      ])

    assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied)

    assert Enum.at(results, 0)["deposit_due_cents"] == 19_500
    assert Enum.at(results, 1)["deposit_due_cents"] == 40_000
    assert Enum.at(results, 2)["outstanding_deposit_cents"] == 9_500
    assert Enum.at(results, 3)["new_departure_on"] == "2026-12-15"

    group = group_data(conn, "group-81")
    assert group["revision"] == 3
    assert group["arrival_on"] == "2026-12-12"
    assert group["departure_on"] == "2026-12-15"
    assert group["deposit_paid_cents"] == 10_000
    assert group["outstanding_deposit_cents"] == 9_500

    assert ledger(conn) == %{
             "cash_held_cents" => 10_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    # A mixed batch: one operation fails, the others still apply.
    results =
      submit(conn, [
        %{
          "operation_id" => "op-1005",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-06",
          "group_id" => "group-82",
          "amount_cents" => 50_000
        },
        %{
          "operation_id" => "op-1006",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-06",
          "group_id" => "group-82",
          "amount_cents" => 40_000
        },
        %{
          "operation_id" => "op-1007",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-25",
          "group_id" => "group-81"
        },
        %{
          "operation_id" => "op-1008",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-09",
          "group_id" => "group-82"
        }
      ])

    assert Enum.map(results, & &1["status"]) == ~w(rejected applied applied applied)
    assert Enum.at(results, 0)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 2)["refunded_cents"] == 10_000
    assert Enum.at(results, 2)["retained_cents"] == 0
    assert Enum.at(results, 3)["refunded_cents"] == 0
    assert Enum.at(results, 3)["retained_cents"] == 40_000

    cancelled = group_data(conn, "group-81")
    assert cancelled["status"] == "cancelled"
    assert cancelled["revision"] == 4
    assert cancelled["outstanding_deposit_cents"] == 0

    advance = group_data(conn, "group-82")
    assert advance["status"] == "cancelled"
    assert advance["revision"] == 3

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 10_000,
             "cash_retained_cents" => 40_000
           }

    # The cancelled groups accept no further changes.
    results =
      submit(conn, [
        %{
          "operation_id" => "op-1009",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-81",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "op-1010",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-82",
          "new_arrival_on" => "2026-12-20"
        }
      ])

    assert Enum.map(results, & &1["code"]) == ~w(group_not_active group_not_active)
  end
end
