defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  describe "GET /api/v1/ledger" do
    test "reports zero totals before any cash is recorded" do
      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "unpaid deposit requirements never appear as cash" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "cash held is cash applied to active reservations" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000}),
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"}),
        payment_operation(%{
          "group_id" => "group-2",
          "operation_id" => "op-pay-2",
          "amount_cents" => 1000
        })
      ])

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "cancellation moves cash to refunded or retained" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 4000}),
        open_group_operation(%{
          "group_id" => "group-2",
          "operation_id" => "op-open-2",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation(%{
          "group_id" => "group-2",
          "operation_id" => "op-pay-2",
          "amount_cents" => 2000
        }),
        cancel_operation(%{"occurred_on" => "2026-11-26"}),
        cancel_operation(%{
          "group_id" => "group-2",
          "operation_id" => "op-cancel-2",
          "occurred_on" => "2026-11-26"
        })
      ])

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4000,
               "cash_retained_cents" => 2000
             }
    end
  end
end
