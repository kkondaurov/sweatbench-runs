defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  defp post_operations(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "returns the full group document for an opened group" do
    conn = build_conn()

    post_operations(conn, [open()])

    assert json_response(get(conn, ~p"/api/v1/groups/group-81"), 200) == %{
             "data" => %{
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
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           }
  end

  test "returns rooms in their original order" do
    conn = build_conn()

    op =
      open(%{
        "rooms" => [
          %{"room_id" => "zebra", "nightly_rate_cents" => 1_000},
          %{"room_id" => "alpha", "nightly_rate_cents" => 2_000}
        ]
      })

    post_operations(conn, [op])

    rooms = json_response(get(conn, ~p"/api/v1/groups/group-81"), 200)["data"]["rooms"]

    assert Enum.map(rooms, & &1["room_id"]) == ["zebra", "alpha"]
  end

  test "reflects applied payments, reschedules and cancellations" do
    conn = build_conn()

    post_operations(conn, [
      open(),
      payment(%{"amount_cents" => 5_000}),
      reschedule(%{"new_arrival_on" => "2026-12-17"})
    ])

    data = json_response(get(conn, ~p"/api/v1/groups/group-81"), 200)["data"]

    assert data["arrival_on"] == "2026-12-17"
    assert data["departure_on"] == "2026-12-20"
    assert data["revision"] == 3
    assert data["deposit_paid_cents"] == 5_000
    assert data["outstanding_deposit_cents"] == 14_500

    post_operations(conn, [cancel(%{"occurred_on" => "2026-10-10"})])

    data = json_response(get(conn, ~p"/api/v1/groups/group-81"), 200)["data"]

    assert data["status"] == "cancelled"
    assert data["revision"] == 4
    assert data["outstanding_deposit_cents"] == 0
  end

  test "returns group identifiers strings unchanged" do
    conn = build_conn()

    post_operations(conn, [open(%{"group_id" => "G-01", "property_id" => "p-42"})])

    data = json_response(get(conn, ~p"/api/v1/groups/G-01"), 200)["data"]

    assert data["group_id"] == "G-01"
    assert data["property_id"] == "p-42"
  end

  test "returns 404 with a stable code for a missing group" do
    conn = build_conn()

    conn = get(conn, ~p"/api/v1/groups/no-such-group")

    assert conn.status == 404
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
