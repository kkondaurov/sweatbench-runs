defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "opens a group, records payment, and returns the group and ledger", %{conn: conn} do
    operations = [
      open_group("open-1"),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10_000,
        "expected_revision" => 1
      }
    ]

    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{operations: operations})
      |> json_response(200)

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               }
             ]
           }

    group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)

    assert group == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 2,
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
               "deposit_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500
             }
           }

    assert conn |> get(~p"/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 10_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "continues after rejected work without creating partial groups", %{conn: conn} do
    invalid_open =
      open_group("bad-open")
      |> Map.put("rooms", [%{"room_id" => "duplicate", "nightly_rate_cents" => 100}])
      |> Map.put("arrival_on", "2026-12-13")
      |> Map.put("departure_on", "2026-12-13")

    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{operations: [invalid_open, open_group("open-2")]})
      |> json_response(200)

    assert response == %{
             "results" => [
               %{"operation_id" => "bad-open", "status" => "rejected", "code" => "invalid_stay"},
               %{
                 "operation_id" => "open-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           }

    assert conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)

    assert conn |> get(~p"/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "calculates flexible deposits per room and rejects duplicate group identifiers", %{
    conn: conn
  } do
    rounding_group =
      open_group("open-rounded")
      |> Map.put("arrival_on", "2026-12-10")
      |> Map.put("departure_on", "2026-12-13")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 1},
        %{"room_id" => "room-b", "nightly_rate_cents" => 1}
      ])

    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{
        operations: [rounding_group, open_group("duplicate")]
      })
      |> json_response(200)

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-rounded",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 2,
                 "revision" => 1
               },
               %{
                 "operation_id" => "duplicate",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               }
             ]
           }
  end

  test "rejects stale revisions before other group domain rules", %{conn: conn} do
    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{
        operations: [
          open_group("open-1"),
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => -1,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "missing-group",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "not-here",
            "amount_cents" => 1,
            "expected_revision" => 1
          }
        ]
      })
      |> json_response(200)

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 19_400,
                 "revision" => 2
               },
               %{
                 "operation_id" => "stale-pay",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               },
               %{
                 "operation_id" => "missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           }
  end

  test "reschedules active groups and settles refundable and retained cash", %{conn: conn} do
    operations = [
      open_group("open-flex"),
      payment("pay-flex", 500, 1),
      %{
        "operation_id" => "move-flex",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-flex",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-06",
        "group_id" => "group-81",
        "expected_revision" => 3
      },
      payment("after-cancel", 1, 4)
    ]

    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{operations: operations})
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "open-flex",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             },
             %{
               "operation_id" => "pay-flex",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 19_000,
               "revision" => 2
             },
             %{
               "operation_id" => "move-flex",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 3
             },
             %{
               "operation_id" => "cancel-flex",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 500,
               "retained_cents" => 0,
               "revision" => 4
             },
             %{
               "operation_id" => "after-cancel",
               "status" => "rejected",
               "code" => "group_not_active"
             }
           ]

    assert conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 4,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-20",
               "departure_on" => "2026-12-23",
               "rate_plan" => "flexible",
               "status" => "cancelled",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 500,
               "outstanding_deposit_cents" => 0
             }
           }

    assert conn |> get(~p"/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 500,
               "cash_retained_cents" => 0
             }
           }
  end

  test "retains late flexible and advance-purchase payments", %{conn: conn} do
    advance_purchase =
      open_group("open-advance")
      |> Map.put("group_id", "group-advance")
      |> Map.put("rate_plan", "advance_purchase")

    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{
        operations: [
          open_group("open-flex"),
          payment("pay-flex", 500, 1),
          %{
            "operation_id" => "cancel-flex",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-81",
            "expected_revision" => 2
          },
          advance_purchase,
          %{
            "operation_id" => "pay-advance",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-advance",
            "amount_cents" => 1_000,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "cancel-advance",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-advance",
            "expected_revision" => 2
          }
        ]
      })
      |> json_response(200)

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "cancel-flex",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 0,
             "retained_cents" => 500,
             "revision" => 3
           }

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "cancel-advance",
             "status" => "applied",
             "group_id" => "group-advance",
             "refunded_cents" => 0,
             "retained_cents" => 1_000,
             "revision" => 3
           }

    assert conn |> get(~p"/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 1_500
             }
           }
  end

  test "validates batches and malformed operations", %{conn: conn} do
    assert conn |> post(~p"/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    response =
      conn
      |> post(~p"/api/v1/partner-batches", %{
        operations: [
          %{"operation_id" => "unknown", "type" => "other", "occurred_on" => "2026-10-03"},
          open_group("bad-rooms") |> Map.put("rooms", []),
          open_group("bad-rate") |> Map.put("rate_plan", "weekend"),
          open_group("good-open"),
          %{
            "operation_id" => "bad-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "too-large",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19_501
          },
          %{
            "operation_id" => "bad-reschedule",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-10-04"
          }
        ]
      })
      |> json_response(200)

    assert Enum.map(response["results"], & &1["code"]) == [
             "invalid_operation",
             "invalid_rooms",
             "invalid_rate_plan",
             nil,
             "invalid_amount",
             "payment_exceeds_outstanding",
             "invalid_stay"
           ]
  end

  defp open_group(operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp payment(operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end
end
