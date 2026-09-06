defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  test "allocates funding by room and cancels selected rooms in original order", %{conn: conn} do
    operations = [
      open("group-1"),
      payment("pay-1", "group-1", 2_500),
      %{
        "operation_id" => "cancel-rooms-1",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-10",
        "group_id" => "group-1",
        "room_ids" => ["room-b", "room-a"],
        "expected_revision" => 2
      }
    ]

    assert %{"results" => [_, _, cancellation]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert cancellation == %{
             "operation_id" => "cancel-rooms-1",
             "status" => "applied",
             "group_id" => "group-1",
             "cancelled_room_ids" => ["room-a", "room-b"],
             "refunded_cents" => 2_500,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    assert group["status"] == "cancelled"
    assert group["lodging_total_cents"] == 0
    assert group["deposit_due_cents"] == 0
    assert group["deposit_paid_cents"] == 0

    assert group["rooms"] == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 5_000,
               "status" => "cancelled",
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 7_500,
               "status" => "cancelled",
               "lodging_total_cents" => 15_000,
               "deposit_due_cents" => 3_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]
  end

  test "rejects invalid room selections atomically", %{conn: conn} do
    duplicate = %{
      "operation_id" => "cancel-rooms-bad",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-1",
      "room_ids" => ["room-a", "room-a"]
    }

    assert %{"results" => [_, %{"code" => "invalid_rooms"}]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => [open("group-1"), duplicate]})
             |> json_response(200)

    assert %{"data" => %{"revision" => 1, "deposit_due_cents" => 5_000}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    malformed = %{
      duplicate
      | "operation_id" => "cancel-rooms-malformed",
        "room_ids" => [%{"bad" => true}]
    }

    assert %{"results" => [%{"code" => "invalid_rooms"}]} =
             post(build_conn(), "/api/v1/partner-batches", %{"operations" => [malformed]})
             |> json_response(200)
  end

  test "reduces only held cash from the target payment and reconciles it", %{conn: conn} do
    reduce = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay-1",
      "amount_cents" => 1_200,
      "expected_revision" => 2
    }

    assert %{"results" => [_, paid, reduced]} =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [open("group-1"), payment("pay-1", "group-1", 3_500), reduce]
             })
             |> json_response(200)

    assert reduced["outstanding_deposit_cents"] == 2_700
    assert reduced["revision"] == 3

    assert %{"data" => statement} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert statement == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "group-1",
             "recorded_cents" => 3_500,
             "held_cents" => 2_300,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 1_200,
             "charged_back_cents" => 0
           }

    assert %{"results" => [replayed]} =
             post(build_conn(), "/api/v1/partner-batches", %{
               "operations" => [payment("pay-1", "group-1", 3_500)]
             })
             |> json_response(200)

    assert replayed == paid

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    assert ledger["cash_held_cents"] == 2_300
    assert ledger["cash_reduced_cents"] == 1_200
  end

  test "partial room settlement leaves other room allocations unchanged", %{conn: conn} do
    cancel_room = %{
      "operation_id" => "cancel-room-a",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-1",
      "room_ids" => ["room-a"]
    }

    reduce = %{
      "operation_id" => "reduce-rest",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay-1",
      "amount_cents" => 500
    }

    assert %{"results" => [_, _, cancelled, reduced]} =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [
                 open("group-1"),
                 payment("pay-1", "group-1", 2_500),
                 cancel_room,
                 reduce
               ]
             })
             |> json_response(200)

    assert cancelled["refunded_cents"] == 2_000
    assert reduced["outstanding_deposit_cents"] == 3_000

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    assert group["status"] == "active"
    assert group["deposit_due_cents"] == 3_000
    assert group["cash_paid_cents"] == 0

    assert %{"data" => statement} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert statement["refunded_cents"] == 2_000
    assert statement["reduced_cents"] == 500
    assert statement["held_cents"] == 0
  end

  test "chargeback revokes converted credit and tracks current shortfall", %{conn: conn} do
    operations = [
      open("source"),
      payment("pay-source", "source", 4_000),
      cancel("source", "hotel_credit"),
      open("target"),
      %{
        "operation_id" => "credit-target",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-11",
        "group_id" => "target",
        "amount_cents" => 4_400
      },
      %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-source",
        "expected_revision" => 3
      }
    ]

    assert %{"results" => results} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert List.last(results)["charged_back_cents"] == 4_000

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2026-10-11") |> json_response(200)

    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 4_000
    assert ledger["credit_liability_cents"] == 4_400
    assert ledger["credit_shortfall_cents"] == 4_400

    assert %{"results" => [%{"status" => "applied"}]} =
             post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancel("target")]})
             |> json_response(200)

    assert %{"data" => settled} =
             get(build_conn(), "/api/v1/ledger?on=2026-10-12") |> json_response(200)

    assert settled["credit_liability_cents"] == 0
    assert settled["credit_shortfall_cents"] == 0
  end

  test "payment reads distinguish missing and non-payment operations", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/payments/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert %{"results" => [_]} =
             post(build_conn(), "/api/v1/partner-batches", %{"operations" => [open("group-1")]})
             |> json_response(200)

    assert json_response(get(build_conn(), "/api/v1/payments/open-group-1"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  defp open(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 5_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 7_500}
      ]
    }
  end

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, method \\ "cash") do
    %{
      "operation_id" => "cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-12",
      "group_id" => group_id,
      "refund_method" => method
    }
  end
end
