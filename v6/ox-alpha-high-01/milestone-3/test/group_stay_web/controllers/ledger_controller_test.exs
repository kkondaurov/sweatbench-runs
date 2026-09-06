defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import Phoenix.ConnTest

  defp ledger(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
  end

  defp run_batch!(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200)
  end

  test "starts at zero", %{conn: conn} do
    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "counts only cash actually paid to active groups", %{conn: conn} do
    run_batch!(conn, [
      open_operation(),
      open_operation(
        operation_id: "op-unpaid",
        group_id: "group-unpaid",
        rate_plan: "advance_purchase"
      ),
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 5000
      }
    ])

    assert ledger(conn)["cash_held_cents"] == 5000
    assert ledger(conn)["cash_refunded_cents"] == 0
    assert ledger(conn)["cash_retained_cents"] == 0
  end

  test "cancellation moves held cash to refunded or retained", %{conn: conn} do
    run_batch!(conn, [
      open_operation(operation_id: "op-flex", group_id: "group-flex"),
      open_operation(
        operation_id: "op-ap",
        group_id: "group-ap",
        rate_plan: "advance_purchase"
      ),
      payment("op-pay-flex", "group-flex", 3000),
      payment("op-pay-ap", "group-ap", 7000),
      cancel("op-cancel-flex", "group-flex", "2026-11-01"),
      cancel("op-cancel-ap", "group-ap", "2026-10-04")
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 3000,
             "cash_retained_cents" => 7000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    run_batch!(conn, [
      open_operation(),
      cancel("op-cancel", "group-81", "2026-11-01")
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end
end
