defmodule GroupStayWeb.Acceptance.GroupsTest do
  use GroupStayWeb.ConnCase

  @open_op %{
    "operation_id" => "op-1",
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
  }

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "returns the full group representation with rooms in their original order" do
    submit(build_conn(), [@open_op])

    conn = get(build_conn(), "/api/v1/groups/group-81")

    assert json_response(conn, 200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
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
           }
  end

  test "reflects payments in the totals" do
    submit(build_conn(), [
      @open_op,
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 7000
      }
    ])

    conn = get(build_conn(), "/api/v1/groups/group-81")
    %{"data" => group} = json_response(conn, 200)

    assert group["deposit_paid_cents"] == 7000
    assert group["outstanding_deposit_cents"] == 12500
    assert group["revision"] == 2
  end

  test "returns cancelled groups" do
    submit(build_conn(), [
      @open_op,
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      }
    ])

    conn = get(build_conn(), "/api/v1/groups/group-81")
    %{"data" => group} = json_response(conn, 200)

    assert group["status"] == "cancelled"
    assert group["revision"] == 2
  end

  test "a missing group returns 404" do
    conn = get(build_conn(), "/api/v1/groups/does-not-exist")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
