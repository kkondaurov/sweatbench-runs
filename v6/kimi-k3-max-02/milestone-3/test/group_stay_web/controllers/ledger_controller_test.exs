defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_operation(group_id, rate_plan) do
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
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
    }
  end

  defp pay_operation(group_id, amount_cents) do
    %{
      "operation_id" => "op-pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, occurred_on) do
    %{
      "operation_id" => "op-cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  test "starts with zeroed totals", %{conn: conn} do
    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cash paid against active reservations is held", %{conn: conn} do
    # flexible, 3 nights x 15000: deposit due is 20% of 45000 = 9000
    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             post_batch(conn, [
               open_operation("group-flex", "flexible"),
               pay_operation("group-flex", 9000)
             ])

    # advance_purchase, 3 nights x 15000: deposit due is the full 45000
    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             post_batch(conn, [
               open_operation("group-advance", "advance_purchase"),
               pay_operation("group-advance", 45000)
             ])

    # an unpaid deposit requirement is not cash and never appears
    assert [%{"status" => "applied"}] =
             post_batch(conn, [open_operation("group-unpaid", "flexible")])

    assert ledger(conn) == %{
             "cash_held_cents" => 54000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cancellation moves held cash to refunded or retained", %{conn: conn} do
    post_batch(conn, [
      open_operation("group-flex", "flexible"),
      pay_operation("group-flex", 9000)
    ])

    post_batch(conn, [
      open_operation("group-advance", "advance_purchase"),
      pay_operation("group-advance", 45000)
    ])

    # 20 days before arrival: flexible cash is refunded
    assert [%{"refunded_cents" => 9000, "retained_cents" => 0}] =
             post_batch(conn, [cancel_operation("group-flex", "2026-11-20")])

    assert ledger(conn) == %{
             "cash_held_cents" => 45000,
             "cash_refunded_cents" => 9000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }

    # advance-purchase cash is retained even when cancelled early
    assert [%{"refunded_cents" => 0, "retained_cents" => 45000}] =
             post_batch(conn, [cancel_operation("group-advance", "2026-11-20")])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 9000,
             "cash_retained_cents" => 45000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "a late flexible cancellation retains the cash", %{conn: conn} do
    post_batch(conn, [
      open_operation("group-flex", "flexible"),
      pay_operation("group-flex", 9000)
    ])

    # 2 days before arrival: non-refundable
    assert [%{"refunded_cents" => 0, "retained_cents" => 9000}] =
             post_batch(conn, [cancel_operation("group-flex", "2026-12-08")])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 9000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  defp credit_cancel_operation(group_id, occurred_on) do
    group_id
    |> cancel_operation(occurred_on)
    |> Map.put("refund_method", "hotel_credit")
  end

  defp apply_credit_operation(group_id, amount_cents) do
    %{
      "operation_id" => "op-apply-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-01",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp ledger_on(conn, on) do
    conn
    |> get(~p"/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "a hotel_credit cancellation converts cash to credit liability", %{conn: conn} do
    post_batch(conn, [
      open_operation("group-flex", "flexible"),
      pay_operation("group-flex", 9000)
    ])

    assert [%{"credit_issued_cents" => 9900}] =
             post_batch(conn, [credit_cancel_operation("group-flex", "2026-11-20")])

    assert ledger_on(conn, "2026-11-20") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 9000,
             "credit_liability_cents" => 9900
           }
  end

  test "the credit liability moves with application, restoration, consumption, and expiry",
       %{conn: conn} do
    post_batch(conn, [
      open_operation("group-flex", "flexible"),
      pay_operation("group-flex", 9000)
    ])

    # lot of 9900 expiring 2027-11-20
    post_batch(conn, [credit_cancel_operation("group-flex", "2026-11-20")])

    # applying credit to an active group does not change the liability
    post_batch(conn, [
      open_operation("group-next", "flexible"),
      apply_credit_operation("group-next", 4000)
    ])

    assert ledger_on(conn, "2026-11-21")["credit_liability_cents"] == 9900

    # a refundable cancellation restores the credit: liability still unchanged
    assert [%{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}] =
             post_batch(conn, [cancel_operation("group-next", "2026-11-25")])

    assert ledger_on(conn, "2026-11-25")["credit_liability_cents"] == 9900

    # apply again, then a non-refundable cancellation consumes the credit
    post_batch(conn, [
      open_operation("group-late", "flexible"),
      apply_credit_operation("group-late", 4000)
    ])

    assert [%{"refunded_cents" => 0, "retained_cents" => 0}] =
             post_batch(conn, [cancel_operation("group-late", "2026-12-09")])

    assert ledger_on(conn, "2026-12-09")["credit_liability_cents"] == 5900

    # expiry reduces the liability the day after the lot's expiry date
    assert ledger_on(conn, "2027-11-20")["credit_liability_cents"] == 5900
    assert ledger_on(conn, "2027-11-21")["credit_liability_cents"] == 0

    # the cash totals are not date-dependent
    assert ledger_on(conn, "2027-11-21")["cash_converted_to_credit_cents"] == 9000
  end

  test "a malformed on date is rejected", %{conn: conn} do
    response =
      conn
      |> get(~p"/api/v1/ledger?on=yesterday")
      |> json_response(422)

    assert response == %{"error" => %{"code" => "invalid_date"}}
  end
end
