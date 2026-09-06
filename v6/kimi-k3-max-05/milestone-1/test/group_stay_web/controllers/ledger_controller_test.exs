defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
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
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount) do
    %{
      "operation_id" => "op-pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_op(group_id, occurred_on) do
    %{
      "operation_id" => "op-cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  test "starts at zero", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "unpaid deposits never appear as cash", %{conn: conn} do
    conn = post_batch(conn, %{"operations" => [open_op("group-81")]})
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{"data" => totals} = json_response(conn, 200)

    assert totals == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "holds cash on active groups and settles it on cancellation", %{conn: conn} do
    operations = [
      # refundable: 20 days before arrival
      open_op("group-81"),
      payment_op("group-81", 9_000),
      # retained: advance purchase on an old-enough booking window
      open_op("group-82", %{"rate_plan" => "advance_purchase"}),
      payment_op("group-82", 7_000),
      # stays active and keeps holding cash
      open_op("group-83"),
      payment_op("group-83", 4_000),
      cancel_op("group-81", "2026-11-20"),
      cancel_op("group-82", "2026-11-20")
    ]

    conn = post_batch(conn, %{"operations" => operations})
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{"data" => totals} = json_response(conn, 200)

    assert totals == %{
             "cash_held_cents" => 4_000,
             "cash_refunded_cents" => 9_000,
             "cash_retained_cents" => 7_000
           }
  end
end
