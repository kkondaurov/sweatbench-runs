defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp open_group(conn, group_id, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => "op-#{group_id}",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => group_id,
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

    conn
    |> post(~p"/api/v1/partner-batches", %{operations: [op]})
    |> json_response(200)
  end

  test "returns a group with identifiers, dates, revision, rooms, and totals", %{conn: conn} do
    group_id = "group-#{System.unique_integer([:positive])}"
    open_group(conn, group_id)

    response =
      conn
      |> get(~p"/api/v1/groups/#{group_id}")
      |> json_response(200)

    assert %{
             "data" => %{
               "group_id" => ^group_id,
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
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           } = response
  end

  test "reflects payments and reschedules in totals and revision", %{conn: conn} do
    group_id = "group-#{System.unique_integer([:positive])}"
    open_group(conn, group_id)

    ops = [
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => 10_000
      },
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-20",
        "group_id" => group_id,
        "new_arrival_on" => "2027-01-05"
      }
    ]

    conn
    |> post(~p"/api/v1/partner-batches", %{operations: ops})
    |> json_response(200)

    response =
      conn
      |> get(~p"/api/v1/groups/#{group_id}")
      |> json_response(200)

    assert %{
             "data" => %{
               "revision" => 3,
               "arrival_on" => "2027-01-05",
               "departure_on" => "2027-01-08",
               "deposit_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500
             }
           } = response
  end

  test "a cancelled group reports its status and zeroed active-room totals", %{conn: conn} do
    group_id = "group-#{System.unique_integer([:positive])}"
    open_group(conn, group_id)

    ops = [
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => 11_000
      },
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      }
    ]

    conn
    |> post(~p"/api/v1/partner-batches", %{operations: ops})
    |> json_response(200)

    response =
      conn
      |> get(~p"/api/v1/groups/#{group_id}")
      |> json_response(200)

    # Group totals describe active rooms only; a cancelled group has none.
    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 3,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } =
             response
  end

  test "a missing group returns 404 with group_not_found", %{conn: conn} do
    response =
      conn
      |> get(~p"/api/v1/groups/group-missing")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "group_not_found"}}
  end
end
