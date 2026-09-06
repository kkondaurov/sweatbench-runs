defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  test "starts at zero", %{conn: conn} do
    conn = get_ledger(conn)

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "counts cash applied to active reservations across groups and ignores unpaid deposits", %{
    conn: conn
  } do
    conn =
      post_operations(conn, [
        open_operation(),
        open_operation(%{
          "group_id" => "group-82",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
        }),
        payment_operation("group-81", 3000),
        payment_operation("group-82", 12_000)
      ])

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"status" => "applied"}
           ] =
             json_response(conn, 200)["results"]

    # group-81 still owes 16500 and group-82 owes nothing; unpaid deposit is not cash.
    assert %{
             "data" => %{
               "cash_held_cents" => 15_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } =
             get_ledger(conn) |> json_response(200)
  end

  test "cancellation moves held cash to refunded or retained", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation(),
        open_operation(%{
          "group_id" => "advance-group",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}]
        }),
        payment_operation("group-81", 4000),
        payment_operation("advance-group", 30_000),
        cancel_operation("group-81"),
        cancel_operation("advance-group", %{
          "operation_id" => "op-cancel-advance",
          "occurred_on" => "2026-10-05"
        })
      ])

    results = json_response(conn, 200)["results"]
    assert Enum.all?(results, &(&1["status"] == "applied"))

    # Flexible cancelled with plenty of notice refunds; advance-purchase retains.
    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4000,
               "cash_retained_cents" => 30_000
             }
           } = get_ledger(conn) |> json_response(200)
  end
end
