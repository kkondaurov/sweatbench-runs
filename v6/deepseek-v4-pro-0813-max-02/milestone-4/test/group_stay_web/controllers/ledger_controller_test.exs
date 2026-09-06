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
               "cash_retained_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
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
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
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
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
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
             "cash_retained_cents" => 10_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
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
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "unpaid deposit requirements are never part of the cash totals" do
    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [open_group_op()]})

    {body, 200} = api_get(build_conn(), "/api/v1/ledger")

    assert body["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  describe "hotel credit" do
    defp post_ops(ops) do
      api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
    end

    defp issue_credit do
      open =
        open_group_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9001",
          "occurred_on" => "2026-01-05",
          "arrival_on" => "2026-06-01",
          "departure_on" => "2026-06-04",
          "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
        })

      payment =
        cash_payment_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9002",
          "amount_cents" => 5_000
        })

      cancellation =
        cancel_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9101",
          "occurred_on" => "2026-04-01",
          "refund_method" => "hotel_credit"
        })

      {_, 200} = post_ops([open, payment, cancellation])
    end

    test "converting cash to credit moves held cash to the conversion total" do
      issue_credit()

      {body, 200} = api_get(build_conn(), "/api/v1/ledger")

      assert body["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "credit_liability_cents" => 5_500,
               "credit_shortfall_cents" => 0
             }
    end

    test "the credit liability is stable across application and restoration" do
      issue_credit()
      {_, 200} = post_ops([open_group_op()])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-04-02", "amount_cents" => 3_000})
        ])

      {body, 200} = api_get(build_conn(), "/api/v1/ledger")
      assert body["data"]["credit_liability_cents"] == 5_500

      {_, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      {body, 200} = api_get(build_conn(), "/api/v1/ledger")
      assert body["data"]["credit_liability_cents"] == 5_500
    end

    test "expired credit stops being part of the liability" do
      issue_credit()

      {body, 200} = api_get(build_conn(), "/api/v1/ledger?on=2027-04-01")
      assert body["data"]["credit_liability_cents"] == 5_500

      {body, 200} = api_get(build_conn(), "/api/v1/ledger?on=2027-04-02")
      assert body["data"]["credit_liability_cents"] == 0
    end
  end
end
