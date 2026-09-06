defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  test "applies a batch in order and keeps rejected operations isolated", %{conn: conn} do
    operations = [
      open_operation("group-81"),
      %{
        "operation_id" => "op-pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      %{
        "operation_id" => "op-pay-too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 20_000
      },
      %{
        "operation_id" => "op-pay-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "amount_cents" => 14_500
      }
    ]

    response = post_batch(conn, operations)

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "op-open-group-81",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-pay-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "op-pay-too-much",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding",
                 "group_id" => "group-81"
               },
               %{
                 "operation_id" => "op-pay-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 14_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             ]
           }

    assert json_response(get(conn, "/api/v1/groups/group-81"), 200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 3,
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
               "deposit_paid_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             }
           }

    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 19_500,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "rounds flexible deposits per room and supports advance purchase", %{conn: conn} do
    operations = [
      open_operation("flexible-group", "2026-12-10", "2026-12-12", [
        %{"room_id" => "one", "nightly_rate_cents" => 101},
        %{"room_id" => "two", "nightly_rate_cents" => 99}
      ]),
      %{
        "operation_id" => "op-open-advance",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "advance-group",
        "guest_id" => "guest-23",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 101}]
      }
    ]

    assert %{"results" => [flexible, advance]} = post_batch(conn, operations)
    assert flexible["deposit_due_cents"] == 80
    assert advance["deposit_due_cents"] == 202
  end

  test "reschedules a stay without changing its length and enforces revisions", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open_operation("move-me")])

    assert %{"results" => [payment]} =
             post_batch(conn, [
               %{
                 "operation_id" => "op-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "move-me",
                 "amount_cents" => 1_000,
                 "expected_revision" => 1
               }
             ])

    assert payment["revision"] == 2

    assert %{"results" => [stale]} =
             post_batch(conn, [
               %{
                 "operation_id" => "op-stale",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "move-me",
                 "new_arrival_on" => "not-a-date",
                 "expected_revision" => 1
               }
             ])

    assert stale == %{
             "operation_id" => "op-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "move-me",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert %{"results" => [moved]} =
             post_batch(conn, [
               %{
                 "operation_id" => "op-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "move-me",
                 "new_arrival_on" => "2026-12-20",
                 "expected_revision" => 2
               }
             ])

    assert moved["new_arrival_on"] == "2026-12-20"
    assert moved["new_departure_on"] == "2026-12-23"
    assert moved["revision"] == 3
  end

  test "cancellation moves paid cash to the correct ledger bucket", %{conn: conn} do
    operations = [
      open_operation("refundable", "2026-12-20", "2026-12-22"),
      open_operation("nonrefundable", "2026-12-20", "2026-12-22", nil, "advance_purchase"),
      %{
        "operation_id" => "op-refund-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "refundable",
        "amount_cents" => 200
      },
      %{
        "operation_id" => "op-retain-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "nonrefundable",
        "amount_cents" => 202
      },
      %{
        "operation_id" => "op-refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "refundable"
      },
      %{
        "operation_id" => "op-retain",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "nonrefundable"
      }
    ]

    assert %{"results" => results} = post_batch(conn, operations)
    assert Enum.at(results, 4)["refunded_cents"] == 200
    assert Enum.at(results, 4)["retained_cents"] == 0
    assert Enum.at(results, 5)["refunded_cents"] == 0
    assert Enum.at(results, 5)["retained_cents"] == 202

    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 200,
               "cash_retained_cents" => 202
             }
           }

    assert %{"results" => [%{"code" => "group_not_active"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "op-after-cancel",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "refundable",
                 "amount_cents" => 1
               }
             ])
  end

  test "returns invalid batch and operation errors without changing state", %{conn: conn} do
    assert json_response(
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", Jason.encode!(%{"wrong" => []})),
             422
           ) == %{"error" => %{"code" => "invalid_batch"}}

    assert %{"results" => [unknown, missing_group]} =
             post_batch(conn, [
               %{"operation_id" => "op-unknown", "type" => "wat"},
               %{
                 "operation_id" => "op-missing",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "does-not-exist",
                 "amount_cents" => 1
               }
             ])

    assert unknown["code"] == "invalid_operation"
    assert missing_group["code"] == "group_not_found"

    assert json_response(get(conn, "/api/v1/groups/does-not-exist"), 404) ==
             %{"error" => %{"code" => "group_not_found"}}
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(
         group_id,
         arrival_on \\ "2026-12-10",
         departure_on \\ "2026-12-13",
         rooms \\ nil,
         rate_plan \\ "flexible"
       ) do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => departure_on,
      "rate_plan" => rate_plan,
      "rooms" =>
        rooms ||
          [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
    }
  end
end
