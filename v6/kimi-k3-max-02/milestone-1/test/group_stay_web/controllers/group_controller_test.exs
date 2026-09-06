defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group!(conn, overrides \\ %{}) do
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
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        },
        overrides
      )

    assert [%{"status" => "applied"}] = post_batch(conn, [operation])
    operation
  end

  defp get_group(conn, group_id) do
    get(conn, ~p"/api/v1/groups/#{group_id}")
  end

  test "a missing group returns 404", %{conn: conn} do
    assert conn
           |> get_group("group-missing")
           |> json_response(404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "returns the group with identifiers, dates, rooms, and totals", %{conn: conn} do
    open_group!(conn)

    assert %{"data" => data} = json_response(get_group(conn, "group-81"), 200)

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
               %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
             ],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }
  end

  test "rooms are returned in their original order", %{conn: conn} do
    open_group!(conn, %{
      "rooms" => [
        %{"room_id" => "room-c", "nightly_rate_cents" => 100},
        %{"room_id" => "room-a", "nightly_rate_cents" => 200},
        %{"room_id" => "room-b", "nightly_rate_cents" => 300}
      ]
    })

    %{"data" => data} = json_response(get_group(conn, "group-81"), 200)

    assert Enum.map(data["rooms"], & &1["room_id"]) == ["room-c", "room-a", "room-b"]
  end

  test "totals and revision follow recorded payments", %{conn: conn} do
    open_group!(conn)

    post_batch(conn, [
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10000
      }
    ])

    %{"data" => data} = json_response(get_group(conn, "group-81"), 200)

    assert data["revision"] == 2
    assert data["deposit_paid_cents"] == 10000
    assert data["outstanding_deposit_cents"] == 9500
  end

  test "a cancelled group reports its cancelled status", %{conn: conn} do
    open_group!(conn)

    post_batch(conn, [
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }
    ])

    %{"data" => data} = json_response(get_group(conn, "group-81"), 200)

    assert data["status"] == "cancelled"
    assert data["revision"] == 2
  end
end
