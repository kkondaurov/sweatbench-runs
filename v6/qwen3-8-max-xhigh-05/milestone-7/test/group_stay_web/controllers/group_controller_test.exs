defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  test "returns group_not_found for an unknown group", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/groups/group-404")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "returns rooms in their original order", %{conn: conn} do
    open_group_fixture(conn, %{
      "rooms" => [
        %{"room_id" => "room-c", "nightly_rate_cents" => 9000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    })

    data = group_data(conn, "group-81")

    assert Enum.map(data["rooms"], & &1["room_id"]) == ["room-c", "room-a", "room-b"]
    # 3 nights: (9000 + 15000 + 17500) * 3
    assert data["lodging_total_cents"] == 124_500
  end

  test "reports the deposit state after a payment", %{conn: conn} do
    open_group_fixture(conn)

    submit_batch(conn, [
      %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 7500
      }
    ])

    data = group_data(conn, "group-81")
    assert data["deposit_due_cents"] == 19500
    assert data["deposit_paid_cents"] == 7500
    assert data["outstanding_deposit_cents"] == 12000
    assert data["revision"] == 2
  end
end
