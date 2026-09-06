defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post_batch_raw(conn, %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a null operations value as an invalid batch", %{conn: conn} do
      conn = post_batch_raw(conn, %{"operations" => nil})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "applies an empty operations list", %{conn: conn} do
      conn = post_batch(conn, [])
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "ignores expected_revision when opening a group", %{conn: conn} do
      conn = post_batch(conn, [open_op(%{"expected_revision" => 99})])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)
    end

    test "opens a flexible group using the documented example", %{conn: conn} do
      conn = post_batch(conn, [open_op()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")

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
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500
               }
             }
    end

    test "requires the full lodging amount as deposit for advance_purchase", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase", "group_id" => "group-ap"})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "deposit_due_cents" => 97500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately half-up", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "group-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 3},
              %{"room_id" => "room-b", "nightly_rate_cents" => 2}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "rejects a duplicate group identifier without creating a second group", %{conn: conn} do
      conn = post_batch(conn, [open_op(), open_op(%{"operation_id" => "op-dup"})])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-dup",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             }
    end

    test "rejects stays shorter than one night", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects empty rooms, duplicate room ids, and negative rates", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"group_id" => "g1", "rooms" => []}),
          open_op(%{
            "group_id" => "g2",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 200}
            ]
          }),
          open_op(%{
            "group_id" => "g3",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]
          })
        ])

      assert %{
               "results" => [
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects an unknown rate plan without creating a group", %{conn: conn} do
      conn = post_batch(conn, [open_op(%{"rate_plan" => "nonrefundable"})])

      assert %{"results" => [%{"code" => "invalid_rate_plan"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "records cash against an active group's outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10000
          }
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 10000,
                   "outstanding_deposit_cents" => 9500,
                   "revision" => 2
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 10000,
                 "outstanding_deposit_cents" => 9500,
                 "revision" => 2
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 10000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "rejects payments that cannot apply", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "missing",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "no-such",
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
            "operation_id" => "negative",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => -1
          },
          %{
            "operation_id" => "over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19501
          },
          %{
            "operation_id" => "full",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19500
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"operation_id" => "missing", "code" => "group_not_found"},
                 %{"operation_id" => "zero", "code" => "invalid_amount"},
                 %{"operation_id" => "negative", "code" => "invalid_amount"},
                 %{"operation_id" => "over", "code" => "payment_exceeds_outstanding"},
                 %{
                   "operation_id" => "full",
                   "status" => "applied",
                   "outstanding_deposit_cents" => 0,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "reschedules an active group by the same number of days", %{conn: conn} do
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

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "revision" => 2
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")

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

    test "rejects a reschedule when the new arrival is not after the operation date", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-20",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert %{"results" => [_, %{"code" => "invalid_stay", "status" => "rejected"}]} =
               json_response(conn, 200)
    end

    test "refunds flexible cash cancelled at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(19500),
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
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 19500,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19500,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "retains flexible cash cancelled fewer than 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
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
                   "retained_cents" => 5000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 5000
               }
             }
    end

    test "cancels unpaid deposit without moving cash", %{conn: conn} do
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

      assert %{
               "results" => [
                 _,
                 %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "never refunds advance_purchase cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(97500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"refunded_cents" => 0, "retained_cents" => 97500, "revision" => 3}
               ]
             } = json_response(conn, 200)
    end

    test "rejects later operations against a cancelled group", %{conn: conn} do
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
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{"operation_id" => "op-pay", "code" => "group_not_active"},
                 %{"operation_id" => "op-move", "code" => "group_not_active"},
                 %{"operation_id" => "op-cancel-2", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)
    end

    test "returns group_not_found before comparing revisions", %{conn: conn} do
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

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "fresh-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500,
            "expected_revision" => 2
          }
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 1000,
                   "outstanding_deposit_cents" => 18500,
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
                   "operation_id" => "fresh-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 18000,
                   "revision" => 3
                 }
               ]
             }
    end

    test "rejects unknown types and incomplete operations then continues the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          %{"operation_id" => "incomplete", "type" => "record_cash_payment"},
          open_op()
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "incomplete",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{"operation_id" => "op-1001", "status" => "applied", "revision" => 1}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns 404 for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "GET /api/v1/ledger" do
    test "sums cash across active and cancelled groups", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"group_id" => "held", "operation_id" => "o1"}),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "held",
            "amount_cents" => 1000
          },
          open_op(%{"group_id" => "refunded", "operation_id" => "o2"}),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "refunded",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "c2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "refunded"
          },
          open_op(%{
            "group_id" => "retained",
            "operation_id" => "o3",
            "rate_plan" => "advance_purchase"
          }),
          %{
            "operation_id" => "p3",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "retained",
            "amount_cents" => 3000
          },
          %{
            "operation_id" => "c3",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "retained"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 1000,
                 "cash_refunded_cents" => 2000,
                 "cash_retained_cents" => 3000
               }
             }
    end

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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
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
