defmodule GroupStayWeb.Controllers.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "returns 404 with a stable code for a missing group", %{conn: conn} do
    conn = get(conn, "/api/v1/groups/never-opened")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "reflects payments and revisions through reads", %{conn: conn} do
    run_batch(conn, [
      open_operation(),
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "amount_cents" => 10_000
      }
    ])

    assert %{
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 10_000,
             "outstanding_deposit_cents" => 9_500,
             "revision" => 2,
             "status" => "active"
           } = fetch_group(conn, "group-81")
  end

  test "a cancelled group no longer reports an outstanding deposit", %{conn: conn} do
    run_batch(conn, [
      open_operation(),
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-30",
        "group_id" => "group-81"
      }
    ])

    group = fetch_group(conn, "group-81")

    assert %{
             "status" => "cancelled",
             "revision" => 3,
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0
           } = group
  end
end
