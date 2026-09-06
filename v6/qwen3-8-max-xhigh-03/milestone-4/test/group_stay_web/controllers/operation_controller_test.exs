defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"

  defp run(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(overrides \\ %{}) do
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
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
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
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp stored(conn, operation_id) do
    conn |> get("/api/v1/operations/#{operation_id}") |> json_response(200)
  end

  describe "show" do
    test "returns the stored result of an applied operation", %{conn: conn} do
      assert [applied] = run(conn, [open_op()])

      assert stored(conn, "op-open") == %{"data" => applied}
    end

    test "returns the stored result of a rejected operation", %{conn: conn} do
      assert [rejected] = run(conn, [payment_op()])
      assert rejected["code"] == "group_not_found"

      assert stored(conn, "op-pay") == %{"data" => rejected}
    end

    test "returns the stored stale revision details", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [rejected] =
               run(conn, [payment_op(%{"operation_id" => "op-stale", "expected_revision" => 9})])

      assert rejected["code"] == "stale_revision"

      response = stored(conn, "op-stale")
      assert response == %{"data" => rejected}
      assert response["data"]["actual_revision"] == 1
    end

    test "exposes only the stored result", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      conn = get(conn, "/api/v1/operations/op-open")
      body = json_response(conn, 200)

      assert Map.keys(body) == ["data"]
      refute body["data"]["payload"]
      refute body["data"]["inserted_at"]
    end

    test "a missing identifier returns operation_not_found", %{conn: conn} do
      conn = get(conn, "/api/v1/operations/op-never-seen")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end
end
