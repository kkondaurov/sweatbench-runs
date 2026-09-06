defmodule GroupStayWeb.LedgerReadTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      assert %{"data" => data} = conn |> get("/api/v1/ledger") |> json_response(200)

      assert data == %{
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
      submit_one(conn, open_group_op())

      assert %{"cash_held_cents" => 0} = read_ledger(conn)
    end

    test "totals cover every group", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-1", group_id: "group-1"}),
        payment_op(%{operation_id: "op-2", group_id: "group-1", amount_cents: 4000}),
        open_group_op(%{operation_id: "op-3", group_id: "group-2"}),
        payment_op(%{operation_id: "op-4", group_id: "group-2", amount_cents: 2500}),
        cancel_op(%{operation_id: "op-5", group_id: "group-2", occurred_on: "2026-11-26"}),
        open_group_op(%{
          operation_id: "op-6",
          group_id: "group-3",
          rate_plan: "advance_purchase"
        }),
        payment_op(%{operation_id: "op-7", group_id: "group-3", amount_cents: 7000}),
        cancel_op(%{operation_id: "op-8", group_id: "group-3"})
      ])

      assert %{
               "cash_held_cents" => 4000,
               "cash_refunded_cents" => 2500,
               "cash_retained_cents" => 7000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             } = read_ledger(conn)
    end

    test "credit applied to an active group stays in the liability", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-1", group_id: "group-1"}),
        payment_op(%{operation_id: "op-2", group_id: "group-1", amount_cents: 4000}),
        cancel_op(%{
          operation_id: "cancel-1",
          group_id: "group-1",
          occurred_on: "2026-11-26",
          refund_method: "hotel_credit"
        }),
        open_group_op(%{
          operation_id: "op-3",
          group_id: "group-2",
          occurred_on: "2026-11-27",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        }),
        credit_op(%{
          operation_id: "op-4",
          group_id: "group-2",
          occurred_on: "2026-11-28",
          amount_cents: 4400
        })
      ])

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 4000,
               "credit_liability_cents" => 4400
             } = read_ledger(conn, on: "2026-11-28")

      assert %{"available_cents" => 0} = read_credit(conn, "guest-22", on: "2026-11-28")
    end
  end
end
