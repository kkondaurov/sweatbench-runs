defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  test "GET /api/v1/ledger starts with zeros", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } = json_response(conn, 200)
  end

  test "unpaid deposit requirements never appear in the ledger" do
    post_batch([open_group_op()])
    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } = json_response(conn, 200)
  end

  test "cash paid toward an active group is held" do
    post_batch([
      open_group_op(),
      record_cash_payment_op(%{"amount_cents" => 12_000})
    ])

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{"data" => %{"cash_held_cents" => 12_000}} = json_response(conn, 200)
  end

  test "cancellation moves held cash to refunded or retained" do
    # refundable: cancelled 20 days before arrival
    post_batch([
      open_group_op(),
      record_cash_payment_op(%{"amount_cents" => 10_000}),
      cancel_group_op(%{"occurred_on" => "2026-11-20"})
    ])

    # non-refundable: cancelled 9 days before arrival
    post_batch([
      open_group_op(%{"group_id" => "group-82"}),
      record_cash_payment_op(%{"group_id" => "group-82", "amount_cents" => 4_000}),
      cancel_group_op(%{"group_id" => "group-82", "occurred_on" => "2026-12-01"})
    ])

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 4_000
             }
           } = json_response(conn, 200)
  end
end
