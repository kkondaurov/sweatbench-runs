defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post_batch_raw(conn, %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a non-list operations field", %{conn: conn} do
      conn = post_batch_raw(conn, %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "accepts an empty operations list", %{conn: conn} do
      conn = post_batch(conn, [])
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "opens a flexible group and returns the rounded deposit", %{conn: conn} do
      conn = post_batch(conn, [open_op()])

      assert [
               %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ] = json_response(conn, 200)["results"]
    end

    test "opens an advance-purchase group with the full lodging amount as deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase", "operation_id" => "op-ap"})
        ])

      assert [
               %{
                 "operation_id" => "op-ap",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 97_500,
                 "revision" => 1
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rounds each flexible room deposit to the nearest cent, half-cent up", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 3},
        %{"room_id" => "room-b", "nightly_rate_cents" => 13}
      ]

      conn =
        post_batch(conn, [
          open_op(%{
            "operation_id" => "op-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => rooms
          })
        ])

      assert [%{"status" => "applied", "deposit_due_cents" => 4}] =
               json_response(conn, 200)["results"]
    end

    test "rejects a duplicate group identifier without creating a second group", %{conn: conn} do
      conn = post_batch(conn, [open_op(), open_op(%{"operation_id" => "op-dup"})])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-dup",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "rejects stays that are not at least one night", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "same-day", "departure_on" => "2026-12-10"}),
          open_op(%{
            "operation_id" => "backwards",
            "group_id" => "group-82",
            "arrival_on" => "2026-12-13",
            "departure_on" => "2026-12-10"
          })
        ])

      assert [
               %{"operation_id" => "same-day", "status" => "rejected", "code" => "invalid_stay"},
               %{"operation_id" => "backwards", "status" => "rejected", "code" => "invalid_stay"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 404)["error"]["code"] == "group_not_found"
    end

    test "rejects empty, duplicate, or malformed rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "none", "rooms" => []}),
          open_op(%{
            "operation_id" => "dup-rooms",
            "group_id" => "group-82",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 200}
            ]
          }),
          open_op(%{
            "operation_id" => "bad-rate",
            "group_id" => "group-83",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]
          })
        ])

      assert [
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rooms"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      conn = post_batch(conn, [open_op(%{"rate_plan" => "nonrefundable"})])

      assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] =
               json_response(conn, 200)["results"]
    end

    test "records a cash payment against the outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects payments that are missing, unusable, or too large", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "missing-group",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "zero",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19_501
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => "missing-group", "code" => "group_not_found"},
               %{"operation_id" => "zero", "code" => "invalid_amount"},
               %{"operation_id" => "over", "code" => "payment_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 0
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "reschedules an active group by shifting the departure date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a reschedule that is not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-same-day",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-10-04"
          },
          %{
            "operation_id" => "op-past",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-10-03"
          },
          %{
            "operation_id" => "op-missing-group",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-same-day",
                 "status" => "rejected",
                 "code" => "invalid_stay"
               },
               %{"operation_id" => "op-past", "status" => "rejected", "code" => "invalid_stay"},
               %{
                 "operation_id" => "op-missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["arrival_on"] == "2026-12-10"
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "refunds a flexible cancellation at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(19_500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 19_500,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]
    end

    test "retains cash when a flexible group is cancelled inside 14 days", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(4000),
          %{
            "operation_id" => "op-late",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 4000,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]
    end

    test "never refunds an advance-purchase cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(97_500),
          %{
            "operation_id" => "op-ap-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 97_500, "revision" => 3}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects later mutations after cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          pay_op(100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-cancel-again",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"operation_id" => "op-pay", "code" => "group_not_active"},
               %{"operation_id" => "op-move", "code" => "group_not_active"},
               %{"operation_id" => "op-cancel-again", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 99_999,
            "expected_revision" => 1
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 1000
    end

    test "returns group_not_found before comparing revisions", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-missing",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "expected_revision" => 1
          }
        ])

      assert [
               %{
                 "operation_id" => "op-missing",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "applies expected_revision against changes from earlier operations in the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          Map.put(pay_op(1000), "expected_revision", 1),
          Map.merge(pay_op(500), %{"operation_id" => "op-pay-2", "expected_revision" => 2})
        ])

      assert [
               %{"revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 18_000}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects unknown types and incomplete operations without stopping the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "explode_group", "group_id" => "group-81"},
          %{"operation_id" => "op-empty"},
          open_op()
        ])

      assert [
               %{
                 "operation_id" => "op-unknown",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "op-empty",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "op-1001", "status" => "applied", "revision" => 1}
             ] = json_response(conn, 200)["results"]
    end

    test "ignores expected_revision on open_group", %{conn: conn} do
      conn = post_batch(conn, [Map.put(open_op(), "expected_revision", 99)])

      assert [%{"status" => "applied", "revision" => 1}] = json_response(conn, 200)["results"]
    end

    test "accepts a payment that exactly clears the outstanding deposit", %{conn: conn} do
      conn = post_batch(conn, [open_op(), pay_op(19_500)])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "does not reuse a cancelled group identifier", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          open_op(%{"operation_id" => "op-reopen"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"operation_id" => "op-reopen", "code" => "group_already_exists"}
             ] = json_response(conn, 200)["results"]
    end

    test "increments revision on a no-cash cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"revision" => 1},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a payment missing amount_cents as invalid_operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-no-amount",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => "op-no-amount", "code" => "invalid_operation"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group with rooms in original order and computed totals", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), pay_op(4500)])

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
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
                 "deposit_paid_cents" => 4500,
                 "outstanding_deposit_cents" => 15_000
               }
             } == json_response(conn, 200)
    end

    test "returns 404 for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "returns rescheduled stay dates without changing price", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["arrival_on"] == "2026-12-20"
      assert data["departure_on"] == "2026-12-23"
      assert data["booked_on"] == "2026-10-03"
      assert data["deposit_due_cents"] == 19_500
      assert data["lodging_total_cents"] == 97_500
      assert data["revision"] == 2
    end

    test "clears outstanding after cancellation", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(2000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["outstanding_deposit_cents"] == 0
      assert data["revision"] == 3
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "holds cash on active groups and moves it on cancellation", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(8000),
          open_op(%{"group_id" => "group-82", "operation_id" => "op-open-2"}),
          Map.merge(pay_op(3000), %{"group_id" => "group-82", "operation_id" => "op-pay-2"}),
          open_op(%{"group_id" => "group-83", "operation_id" => "op-open-3"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-83", "operation_id" => "op-pay-3"}),
          %{
            "operation_id" => "refund",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-82"
          },
          %{
            "operation_id" => "retain",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-83"
          }
        ])

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 8000,
                 "cash_refunded_cents" => 3000,
                 "cash_retained_cents" => 2000
               }
             }
    end

    test "does not treat unpaid deposit as cash", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op()])

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end
  end

  defp open_and_return(conn, operations) do
    conn = post_batch(conn, operations)
    assert conn.status == 200
    {:ok, conn}
  end

  defp post_batch(conn, operations) do
    post_batch_raw(conn, %{"operations" => operations})
  end

  defp post_batch_raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp pay_op(amount_cents) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end
end
