defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase

  test "returns the stored result for an applied operation", %{conn: conn} do
    original = open_group_fixture(conn)

    conn = get(conn, ~p"/api/v1/operations/op-1001")

    assert json_response(conn, 200) == %{"data" => original}
  end

  test "returns the stored result for a rejected operation", %{conn: conn} do
    open_group_fixture(conn)

    operation = %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => 999_999
    }

    %{"results" => [rejected]} = submit_batch(conn, [operation])
    assert rejected["status"] == "rejected"
    assert rejected["code"] == "payment_exceeds_outstanding"

    conn = get(conn, ~p"/api/v1/operations/op-pay")

    assert json_response(conn, 200) == %{"data" => rejected}
  end

  test "returns the original result after the group has moved on", %{conn: conn} do
    open_group_fixture(conn)

    payment = %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => 5000
    }

    %{"results" => [applied]} = submit_batch(conn, [payment])
    assert applied["revision"] == 2

    submit_batch(conn, [%{payment | "operation_id" => "op-more", "amount_cents" => 1000}])
    assert group_data(conn, "group-81")["revision"] == 3

    conn = get(conn, ~p"/api/v1/operations/op-pay")

    assert json_response(conn, 200) == %{"data" => applied}
  end

  test "returns operation_not_found for an unknown identifier", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/operations/op-missing")

    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "exposes only the stored result", %{conn: conn} do
    open_group_fixture(conn)

    conn = get(conn, ~p"/api/v1/operations/op-1001")
    body = json_response(conn, 200)

    assert Map.keys(body) == ["data"]

    assert body["data"] == %{
             "operation_id" => "op-1001",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19500,
             "revision" => 1
           }
  end
end
