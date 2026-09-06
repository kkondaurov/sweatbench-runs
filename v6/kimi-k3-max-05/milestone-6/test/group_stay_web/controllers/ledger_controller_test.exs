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
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
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
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
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
             "cash_retained_cents" => 7_000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "a credit settlement moves cash into converted and starts the liability", %{conn: conn} do
    operations = [
      open_op("group-81"),
      payment_op("group-81", 9_000),
      Map.put(cancel_op("group-81", "2026-11-20"), "refund_method", "hotel_credit")
    ]

    conn = post_batch(conn, %{"operations" => operations})
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{"data" => totals} = json_response(conn, 200)

    assert totals == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 9_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 9_900,
             "credit_shortfall_cents" => 0
           }
  end

  test "credit applied to an active group stays in the liability but never counts as cash",
       %{conn: conn} do
    operations = [
      open_op("group-81"),
      payment_op("group-81", 9_000),
      Map.put(cancel_op("group-81", "2026-11-20"), "refund_method", "hotel_credit"),
      open_op("group-82", %{"occurred_on" => "2026-11-21"}),
      %{
        "operation_id" => "op-credit-82",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-22",
        "group_id" => "group-82",
        "amount_cents" => 4_000
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{"data" => totals} = json_response(conn, 200)

    assert %{
             "cash_held_cents" => 0,
             "cash_converted_to_credit_cents" => 9_000,
             "credit_liability_cents" => 9_900
           } = totals
  end

  test "the on date shifts expiry: available credit lapses, applied credit survives",
       %{conn: conn} do
    # the lot from cancelling group-81 expires on 2027-11-20
    operations = [
      open_op("group-81"),
      payment_op("group-81", 9_000),
      Map.put(cancel_op("group-81", "2026-11-20"), "refund_method", "hotel_credit"),
      open_op("group-82", %{
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2028-03-01",
        "departure_on" => "2028-03-02"
      }),
      %{
        "operation_id" => "op-credit-82",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-10",
        "group_id" => "group-82",
        "amount_cents" => 3_000
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})

    conn = get(conn, ~p"/api/v1/ledger?on=2027-11-20")
    assert %{"data" => %{"credit_liability_cents" => 9_900}} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2027-11-21")
    assert %{"data" => %{"credit_liability_cents" => 3_000}} = json_response(conn, 200)
  end

  test "consuming credit on a non-refundable cancellation reduces the liability", %{conn: conn} do
    operations = [
      open_op("group-81"),
      payment_op("group-81", 9_000),
      Map.put(cancel_op("group-81", "2026-11-20"), "refund_method", "hotel_credit"),
      open_op("group-82", %{"occurred_on" => "2026-11-21"}),
      %{
        "operation_id" => "op-credit-82",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-22",
        "group_id" => "group-82",
        "amount_cents" => 4_000
      },
      # 3 days before arrival: inside the flex-14 window
      cancel_op("group-82", "2026-12-07")
    ]

    conn = post_batch(conn, %{"operations" => operations})
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{"data" => %{"credit_liability_cents" => 5_900}} = json_response(conn, 200)
  end
end
