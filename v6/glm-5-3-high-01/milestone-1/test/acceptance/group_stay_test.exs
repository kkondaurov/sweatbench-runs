defmodule GroupStay.AcceptanceTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  @moduledoc false

  test "a group travels from opening through funding, reschedule, and cancellation" do
    conn = build_conn()

    assert [
             %{"status" => "applied", "deposit_due_cents" => 19500, "revision" => 1}
           ] =
             apply_operations!(conn, [
               %{
                 "operation_id" => "op-1001",
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
             ])

    assert [
             %{"outstanding_deposit_cents" => 9500, "revision" => 2},
             %{"outstanding_deposit_cents" => 0, "revision" => 3}
           ] =
             apply_operations!(conn, [
               payment_operation(%{
                 "operation_id" => "op-1002",
                 "group_id" => "group-81",
                 "amount_cents" => 10000
               }),
               payment_operation(%{
                 "operation_id" => "op-1003",
                 "group_id" => "group-81",
                 "amount_cents" => 9500
               })
             ])

    assert [
             %{
               "new_arrival_on" => "2026-12-15",
               "new_departure_on" => "2026-12-18",
               "revision" => 4
             }
           ] =
             apply_operations!(conn, [
               reschedule_operation(%{"operation_id" => "op-1004", "group_id" => "group-81"})
             ])

    conn = get(conn, "/api/v1/ledger")
    assert json_response(conn, 200)["data"]["cash_held_cents"] == 19500

    assert [
             %{"refunded_cents" => 19500, "retained_cents" => 0, "revision" => 5}
           ] =
             apply_operations!(build_conn(), [
               cancel_operation(%{
                 "operation_id" => "op-1005",
                 "group_id" => "group-81",
                 "occurred_on" => "2026-11-26"
               })
             ])

    conn = get(build_conn(), "/api/v1/groups/group-81")
    assert json_response(conn, 200)["data"]["status"] == "cancelled"

    conn = get(build_conn(), "/api/v1/ledger")

    assert json_response(conn, 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 19500,
             "cash_retained_cents" => 0
           }

    conn =
      submit(build_conn(), [
        payment_operation(%{"operation_id" => "op-1006", "group_id" => "group-81"}),
        reschedule_operation(%{"operation_id" => "op-1007", "group_id" => "group-81"}),
        cancel_operation(%{"operation_id" => "op-1008", "group_id" => "group-81"})
      ])

    assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) ==
             ["group_not_active", "group_not_active", "group_not_active"]
  end
end
