defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @operation_path "/api/v1/operations"

  defp open_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  test "returns the stored result of an applied operation", %{conn: conn} do
    {conn, [result]} = post_batch(conn, [open_group_op()])
    assert result["status"] == "applied"

    conn = get(conn, "#{@operation_path}/op-open")
    assert json_response(conn, 200) == %{"data" => result}
  end

  test "returns the stored result of a rejected operation", %{conn: conn} do
    {conn, [result]} = post_batch(conn, [payment_op()])
    assert result["status"] == "rejected"
    assert result["code"] == "group_not_found"

    conn = get(conn, "#{@operation_path}/op-pay")
    assert json_response(conn, 200) == %{"data" => result}
  end

  test "retries and conflicts do not change the stored result", %{conn: conn} do
    {conn, _} = post_batch(conn, [open_group_op()])
    {conn, [result]} = post_batch(conn, [payment_op()])
    assert result["status"] == "applied"

    {conn, [_retry]} = post_batch(conn, [payment_op()])

    {conn, [_conflict]} =
      post_batch(conn, [payment_op(%{"operation_id" => "op-pay", "amount_cents" => 9999})])

    conn = get(conn, "#{@operation_path}/op-pay")
    assert json_response(conn, 200) == %{"data" => result}
  end

  test "returns the stored stale_revision details", %{conn: conn} do
    {conn, _} = post_batch(conn, [open_group_op()])
    {conn, _} = post_batch(conn, [payment_op(%{"operation_id" => "pay-1"})])

    {conn, [result]} =
      post_batch(conn, [payment_op(%{"operation_id" => "pay-stale", "expected_revision" => 1})])

    assert result["code"] == "stale_revision"

    conn = get(conn, "#{@operation_path}/pay-stale")
    assert json_response(conn, 200) == %{"data" => result}
  end

  test "a missing identifier is not found", %{conn: conn} do
    conn = get(conn, "#{@operation_path}/never-submitted")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end
end
