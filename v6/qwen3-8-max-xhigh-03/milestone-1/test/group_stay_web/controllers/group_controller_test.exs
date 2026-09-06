defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  defp open_group(conn, overrides \\ %{}) do
    operation =
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
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        },
        overrides
      )

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: [operation]}))
    |> json_response(200)
  end

  test "returns the group with its totals and rooms in their original order", %{conn: conn} do
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
             "rooms" => [
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }
  end

  test "returns identifiers unchanged", %{conn: conn} do
    open_group(conn, %{"group_id" => "Group 81/AMS", "guest_id" => "G-22", "property_id" => "P-9"})

    data =
      conn
      |> get("/api/v1/groups/Group%2081%2FAMS")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["group_id"] == "Group 81/AMS"
    assert data["guest_id"] == "G-22"
    assert data["property_id"] == "P-9"
  end

  test "returns 404 for a missing group", %{conn: conn} do
    response = get(conn, "/api/v1/groups/group-missing")

    assert json_response(response, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
