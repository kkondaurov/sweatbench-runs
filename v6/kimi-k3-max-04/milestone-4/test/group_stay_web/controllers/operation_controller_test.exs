defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
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

  test "returns the stored applied result", %{conn: conn} do
    group_id = "group-#{System.unique_integer([:positive])}"
    op = open_op(group_id)
    submit(conn, [op])

    response =
      conn
      |> get(~p"/api/v1/operations/#{op["operation_id"]}")
      |> json_response(200)

    assert %{
             "data" => %{
               "operation_id" => _,
               "status" => "applied",
               "group_id" => ^group_id,
               "revision" => 1
             }
           } = response
  end

  test "returns the stored rejected result as well", %{conn: conn} do
    op = %{"operation_id" => "op-rejected", "type" => "wobble"}
    submit(conn, [op])

    response =
      conn
      |> get(~p"/api/v1/operations/op-rejected")
      |> json_response(200)

    assert %{"data" => %{"status" => "rejected", "code" => "invalid_operation"}} = response
  end

  test "a missing identifier returns 404 operation_not_found", %{conn: conn} do
    response =
      conn
      |> get(~p"/api/v1/operations/op-missing")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "operation_not_found"}}
  end
end
