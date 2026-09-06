defmodule GroupStayWeb.Controllers.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-01",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id) do
    %{
      "operation_id" => "op-cancel-" <> group_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => group_id
    }
  end

  test "starts at zero", %{conn: conn} do
    assert fetch_ledger(conn) == %{
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

  test "counts cash applied to active reservations as held", %{conn: conn} do
    run_batch(conn, [
      open_operation(%{"operation_id" => "op-open-one", "group_id" => "g-one"}),
      payment("p1", "g-one", 5_000),
      open_operation(%{
        "operation_id" => "op-open-two",
        "group_id" => "g-two",
        "rate_plan" => "advance_purchase"
      }),
      payment("p2", "g-two", 7_500)
    ])

    assert_ledger(conn, cash_held_cents: 12_500, cash_refunded_cents: 0, cash_retained_cents: 0)
  end

  test "unpaid deposits are not cash and never appear in the totals", %{conn: conn} do
    run_batch(conn, [open_operation()])

    assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0)
  end

  test "refundable cancellations move held cash to refunded", %{conn: conn} do
    run_batch(conn, [
      open_operation(%{"group_id" => "g-refund"}),
      payment("p1", "g-refund", 6_000)
    ])

    run_batch(conn, [cancel("g-refund")])

    assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 6_000, cash_retained_cents: 0)
  end

  test "non-refundable cancellations move held cash to retained", %{conn: conn} do
    run_batch(conn, [
      open_operation(%{"group_id" => "g-keep", "rate_plan" => "advance_purchase"}),
      payment("p1", "g-keep", 9_000)
    ])

    run_batch(conn, [%{cancel("g-keep") | "occurred_on" => "2026-10-04"}])

    assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 9_000)
  end

  test "rejected operations leave the ledger untouched", %{conn: conn} do
    run_batch(conn, [open_operation(), payment("p1", "group-81", 5_000)])

    run_batch(conn, [
      payment("too-much", "group-81", 999_999),
      payment("missing-group", "ghost", 100),
      open_operation(%{"operation_id" => "dup"})
    ])

    assert_ledger(conn, cash_held_cents: 5_000, cash_refunded_cents: 0, cash_retained_cents: 0)
  end

  defp assert_ledger(conn, expectations) do
    assert fetch_ledger(conn) ==
             Map.merge(
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               },
               Map.new(expectations, fn {k, v} -> {Atom.to_string(k), v} end)
             )
  end
end
