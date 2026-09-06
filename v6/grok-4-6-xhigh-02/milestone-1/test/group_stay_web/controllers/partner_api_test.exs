defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "opens a flexible group and returns the deposit", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "calculates advance-purchase deposit as full lodging", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-ap",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 97500, "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately then sums", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-round",
            "group_id" => "group-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 1003},
              %{"room_id" => "room-b", "nightly_rate_cents" => 1003}
            ]
          })
        ])

      assert %{"results" => [%{"status" => "applied", "deposit_due_cents" => 402}]} =
               json_response(conn, 200)
    end

    test "rejects a duplicate group identifier", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), open_group_op(%{"operation_id" => "op-dup"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-dup",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects a stay with no nights", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-stay",
            "group_id" => "group-stay",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects departure before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-stay2",
            "group_id" => "group-stay2",
            "arrival_on" => "2026-12-13",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects empty or duplicate rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-empty",
            "group_id" => "group-empty",
            "rooms" => []
          }),
          open_group_op(%{
            "operation_id" => "op-dup-rooms",
            "group_id" => "group-dup-rooms",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-plan",
            "group_id" => "group-plan",
            "rate_plan" => "nonrefundable"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rate_plan"}]} =
               json_response(conn, 200)
    end

    test "does not create a group when open_group is rejected", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-bad",
            "group_id" => "group-bad",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [%{"status" => "rejected"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-bad")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end

    test "records cash against an outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects payments that are missing, inactive, unusable, or too large", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-missing",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing-group",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-zero",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "op-over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19501
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"code" => "group_not_found"},
                 %{"code" => "invalid_amount"},
                 %{"code" => "payment_exceeds_outstanding"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500
               }
             } =
               json_response(conn, 200)
    end

    test "reschedules an active group by the same number of days", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "revision" => 2
               }
             } = json_response(conn, 200)
    end

    test "rejects a reschedule whose arrival is not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move-bad",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-20",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 19500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 19500,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)
    end

    test "retains cash for a flexible group cancelled fewer than 14 days before arrival", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 8000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)
    end

    test "uses the current arrival when deciding a flexible refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 19500),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-01-20"
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-12",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 19500, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "never refunds an advance-purchase cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-open",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          }),
          cash_payment_op("op-pay", 10000, "group-ap"),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10000}
               ]
             } = json_response(conn, 200)
    end

    test "rejects later mutations on a cancelled group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          cash_payment_op("op-pay", 100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "revision" => 2},
                 %{"code" => "group_not_active"},
                 %{"code" => "group_not_active"},
                 %{"code" => "group_not_active"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 2,
                 "outstanding_deposit_cents" => 0
               }
             } =
               json_response(conn, 200)
    end

    test "increments revision once per applied mutation and ignores expected_revision on open", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(%{"expected_revision" => 99}),
          cash_payment_op("op-pay", 100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-11"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{"status" => "applied", "revision" => 3}
               ]
             } = json_response(conn, 200)
    end

    test "resolves a missing group before comparing revisions", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100,
            "expected_revision" => 1
          }
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_group_op(), cash_payment_op("op-pay", 5000)])
      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-stale",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "revision" => 2,
                 "deposit_paid_cents" => 5000,
                 "outstanding_deposit_cents" => 14500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 5000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               json_response(conn, 200)
    end

    test "sees earlier operations in the same batch when checking expected_revision", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          Map.put(cash_payment_op("op-pay", 100), "expected_revision", 1),
          Map.put(cash_payment_op("op-pay-2", 100), "expected_revision", 1)
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unknown types and incomplete operations without stopping the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          %{
            "operation_id" => "op-incomplete",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-03"
          },
          open_group_op()
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "op-incomplete",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{"operation_id" => "op-1001", "status" => "applied"}
               ]
             } = json_response(conn, 200)
    end

    test "returns 422 when the body has no operations array", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/partner-batches", Jason.encode!(%{not_operations: []}))

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "accepts an empty operations list", %{conn: conn} do
      conn = post_batch(conn, [])
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "accepts params posted as maps", %{conn: conn} do
      conn =
        conn
        |> recycle()
        |> post(~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_op(%{"operation_id" => "op-map", "group_id" => "group-map"})
          ]
        })

      assert %{
               "results" => [%{"status" => "applied", "group_id" => "group-map", "revision" => 1}]
             } =
               json_response(conn, 200)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns partner identifiers, rooms in order, and deposit totals", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
            ]
          }),
          cash_payment_op("op-pay", 4500)
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

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
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 4500,
                 "outstanding_deposit_cents" => 15000
               }
             } = json_response(conn, 200)
    end

    test "returns 404 for an unknown group", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/groups/missing")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero and tracks held, refunded, and retained cash", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(),
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("op-pay-1", 5000),
          cash_payment_op("op-pay-2", 3000, "group-82"),
          %{
            "operation_id" => "op-cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-09",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 5000,
                 "cash_retained_cents" => 3000
               }
             } = json_response(conn, 200)
    end

    test "does not treat unpaid deposit as cash", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp get_json(conn, path) do
    conn
    |> recycle()
    |> get(path)
  end

  defp open_group_op(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp cash_payment_op(operation_id, amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
