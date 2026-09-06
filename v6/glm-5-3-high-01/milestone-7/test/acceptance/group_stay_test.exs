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
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
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

  test "a refundable cancellation can fund a later reservation with hotel credit" do
    conn = build_conn()

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"credit_issued_cents" => 5500, "refunded_cents" => 0, "retained_cents" => 0}
           ] =
             apply_operations!(conn, [
               open_group_operation(%{"group_id" => "group-1"}),
               payment_operation(%{"group_id" => "group-1", "amount_cents" => 5000}),
               cancel_operation(%{"group_id" => "group-1", "refund_method" => "hotel_credit"})
             ])

    assert [
             %{"outstanding_deposit_cents" => 3500, "amount_cents" => 5500, "revision" => 2}
           ] =
             apply_operations!(build_conn(), [
               open_group_operation(%{
                 "group_id" => "group-2",
                 "operation_id" => "op-open-2"
               }),
               apply_credit_operation(%{
                 "group_id" => "group-2",
                 "amount_cents" => 5500,
                 "occurred_on" => "2026-10-10"
               })
             ])
             |> Enum.drop(1)

    conn = get(build_conn(), "/api/v1/groups/group-2")
    data = json_response(conn, 200)["data"]
    assert data["cash_paid_cents"] == 0
    assert data["credit_paid_cents"] == 5500

    conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
    assert json_response(conn, 200)["data"]["available_cents"] == 0

    conn = get(build_conn(), "/api/v1/ledger")
    assert json_response(conn, 200)["data"]["credit_liability_cents"] == 5500

    assert [%{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}] =
             apply_operations!(build_conn(), [
               cancel_operation(%{
                 "group_id" => "group-2",
                 "occurred_on" => "2026-11-26",
                 "operation_id" => "op-cancel-2"
               })
             ])

    conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

    assert json_response(conn, 200)["data"] == %{
             "guest_id" => "guest-22",
             "available_cents" => 5500,
             "lots" => [
               %{
                 "source_operation_id" => "op-cancel",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-11-26"
               }
             ]
           }

    conn = get(build_conn(), "/api/v1/ledger")

    assert json_response(conn, 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 5500
           }
  end
end
