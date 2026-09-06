defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp open_group(conn, overrides \\ %{}) do
    op =
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
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        },
        overrides
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: [op]}))

    [result] = json_response(conn, 200)["results"]
    assert result["status"] == "applied"
    :ok
  end

  test "returns a group with its identifiers, dates, rooms, and totals", %{conn: conn} do
    open_group(conn)

    data =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "revision" => 1,
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
             ],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }
  end

  test "rooms are returned in their original order", %{conn: conn} do
    open_group(conn, %{
      "rooms" => [
        %{"room_id" => "room-c", "nightly_rate_cents" => 9000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    })

    data =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data["rooms"], & &1["room_id"]) == ~w(room-c room-a room-b)
  end

  test "returns the partner identifier unchanged", %{conn: conn} do
    open_group(conn, %{"group_id" => "Group 81/AMS"})

    data =
      conn
      |> get("/api/v1/groups/Group%2081%2FAMS")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["group_id"] == "Group 81/AMS"
  end

  test "a missing group returns 404", %{conn: conn} do
    assert conn |> get("/api/v1/groups/nope") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}
  end
end
