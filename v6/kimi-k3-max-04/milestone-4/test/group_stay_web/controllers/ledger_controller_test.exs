defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      },
      overrides
    )
  end

  test "starts at zero", %{conn: conn} do
    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "cash applied to active reservations is held", %{conn: conn} do
    group_id = "group-#{System.unique_integer([:positive])}"

    submit(conn, [
      open_op(group_id),
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => 4_000
      }
    ])

    assert %{"data" => %{"cash_held_cents" => 4_000}} = ledger(conn)
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    group_id = "group-#{System.unique_integer([:positive])}"
    submit(conn, [open_op(group_id)])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           } = ledger(conn)
  end

  test "cancellation moves held cash to refunded or retained", %{conn: conn} do
    refundable = "group-#{System.unique_integer([:positive])}"
    nonrefundable = "group-#{System.unique_integer([:positive])}"

    # Refundable: flexible cancelled 14+ days before arrival.
    submit(conn, [
      open_op(refundable),
      %{
        "operation_id" => "op-pay-1",
        "type" => "record_cash_payment",
        "group_id" => refundable,
        "amount_cents" => 4_000
      },
      %{
        "operation_id" => "op-cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => refundable
      }
    ])

    # Non-refundable: flexible cancelled inside 14 days.
    submit(conn, [
      open_op(nonrefundable),
      %{
        "operation_id" => "op-pay-2",
        "type" => "record_cash_payment",
        "group_id" => nonrefundable,
        "amount_cents" => 7_000
      },
      %{
        "operation_id" => "op-cancel-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => nonrefundable
      }
    ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4_000,
               "cash_retained_cents" => 7_000
             }
           } = ledger(conn)
  end
end
