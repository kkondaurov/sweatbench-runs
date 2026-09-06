defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  test "starts with zero finance totals" do
    {body, status} = api_get(build_conn(), "/api/v1/ledger")

    assert status == 200

    assert body == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "held cash is cash applied to active reservations" do
    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [open_group_op()]})

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [cash_payment_op(%{"amount_cents" => 10_000})]
      })

    {body, 200} = api_get(build_conn(), "/api/v1/ledger")

    assert body["data"] == %{
             "cash_held_cents" => 10_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "cancellation moves held cash to refunded" do
    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [open_group_op()]})

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [cash_payment_op(%{"amount_cents" => 10_000})]
      })

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [cancel_op(%{"occurred_on" => "2026-11-26"})]
      })

    {body, 200} = api_get(build_conn(), "/api/v1/ledger")

    assert body["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 10_000,
             "cash_retained_cents" => 0
           }
  end

  test "cancellation moves held cash to retained for late cancellations" do
    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [open_group_op(%{"rate_plan" => "advance_purchase"})]
      })

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [cash_payment_op(%{"amount_cents" => 10_000})]
      })

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [cancel_op(%{"occurred_on" => "2026-10-10"})]
      })

    {body, 200} = api_get(build_conn(), "/api/v1/ledger")

    assert body["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 10_000
           }
  end

  test "totals combine every reservation" do
    other_open = open_group_op(%{"group_id" => "group-82", "operation_id" => "op-1002"})

    other_keep =
      cash_payment_op(%{
        "group_id" => "group-82",
        "operation_id" => "op-6001",
        "amount_cents" => 7_000
      })

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [
          open_group_op(),
          cash_payment_op(%{"amount_cents" => 5_000}),
          other_open,
          other_keep
        ]
      })

    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [cancel_op(%{"occurred_on" => "2026-11-26"})]
      })

    {body, 200} = api_get(build_conn(), "/api/v1/ledger")

    assert body["data"] == %{
             "cash_held_cents" => 7_000,
             "cash_refunded_cents" => 5_000,
             "cash_retained_cents" => 0
           }
  end

  test "unpaid deposit requirements are never part of the cash totals" do
    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [open_group_op()]})

    {body, 200} = api_get(build_conn(), "/api/v1/ledger")

    assert body["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end
end
