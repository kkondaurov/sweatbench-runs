defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
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
  end

  test "opens and reads a group with ordered rooms and totals", %{conn: conn} do
    response = submit(conn, [open_operation("group-81")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-group-81",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = json_response(response, 200)

    conn = get(conn, "/api/v1/groups/group-81")

    assert %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = json_response(conn, 200)
  end

  test "processes funding, moving, and cancellation in order", %{conn: conn} do
    operations = [
      open_operation("group-lifecycle", %{
        "occurred_on" => "2026-01-01",
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-13",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "group-lifecycle",
        "amount_cents" => 2_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "group-lifecycle",
        "new_arrival_on" => "2026-02-20",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-30",
        "group_id" => "group-lifecycle",
        "expected_revision" => 3
      }
    ]

    response = submit(conn, operations)

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "outstanding_deposit_cents" => 4_000, "revision" => 2},
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-02-20",
                 "new_departure_on" => "2026-02-23",
                 "revision" => 3
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 2_000,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } = json_response(response, 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2_000,
               "cash_retained_cents" => 0
             }
           } =
             json_response(get(conn, "/api/v1/ledger"), 200)

    assert %{
             "data" => %{
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           } =
             json_response(get(conn, "/api/v1/groups/group-lifecycle"), 200)
  end

  test "rejects stale revisions before other validation and continues the batch", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-revisions", %{
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        }),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-revisions",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "pay-stale",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-revisions",
          "amount_cents" => 0,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "pay-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-revisions",
          "amount_cents" => 1_000,
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "pay-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-revisions",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               },
               %{"status" => "applied", "revision" => 3}
             ]
           } = json_response(response, 200)
  end

  test "uses the full advance-purchase deposit and retains late cancellation cash", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-advance", %{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-12"
        }),
        %{
          "operation_id" => "pay-advance",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-advance",
          "amount_cents" => 20_000
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-advance"
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "deposit_due_cents" => 20_000, "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 20_000}
             ]
           } = json_response(response, 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 20_000
             }
           } =
             json_response(get(conn, "/api/v1/ledger"), 200)
  end

  test "rejects invalid group data without creating it", %{conn: conn} do
    assert {:error, changeset} = GroupStay.Groups.insert_group(%{}, [])
    refute changeset.valid?

    response =
      submit(conn, [
        open_operation("group-invalid-stay", %{
          "arrival_on" => "2026-12-12",
          "departure_on" => "2026-12-10"
        }),
        open_operation("group-invalid-rooms", %{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 11_000}
          ]
        }),
        open_operation("group-invalid-rate", %{"rate_plan" => "non_refundable"}),
        open_operation("group-invalid-date", %{"occurred_on" => nil}),
        open_operation("group-invalid-rooms-type", %{"rooms" => nil}),
        Map.delete(open_operation("group-invalid-operation"), "operation_id")
      ])

    assert %{
             "results" => [
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rate_plan"},
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_operation"}
             ]
           } =
             json_response(response, 200)

    response = get(conn, "/api/v1/groups/group-invalid-stay")
    assert json_response(response, 404)["error"]["code"] == "group_not_found"
  end

  test "keeps rejected updates side-effect free and rejects inactive groups", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-errors", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        open_operation("group-errors", %{"operation_id" => "open-group-errors-duplicate"}),
        %{
          "operation_id" => "pay-zero",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors",
          "amount_cents" => 0
        },
        %{
          "operation_id" => "pay-too-much",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors",
          "amount_cents" => 2_001
        },
        %{
          "operation_id" => "pay-bad-date",
          "type" => "record_cash_payment",
          "occurred_on" => "not-a-date",
          "group_id" => "group-errors",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "move-bad-date",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors",
          "new_arrival_on" => "2026-10-04"
        },
        %{
          "operation_id" => "cancel-bad-date",
          "type" => "cancel_group",
          "occurred_on" => "not-a-date",
          "group_id" => "group-errors"
        },
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors"
        },
        %{
          "operation_id" => "pay-inactive",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-errors",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "move-inactive",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-errors",
          "new_arrival_on" => "2026-12-11"
        },
        %{
          "operation_id" => "cancel-inactive",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-errors"
        },
        %{
          "operation_id" => "missing-group",
          "type" => "record_cash_payment",
          "group_id" => "missing-group",
          "amount_cents" => 1
        },
        %{"operation_id" => "unknown", "type" => "something_else"},
        nil
      ])

    assert %{"results" => results} = json_response(response, 200)

    assert Enum.map(results, &Map.get(&1, "code")) == [
             nil,
             "group_already_exists",
             "invalid_amount",
             "payment_exceeds_outstanding",
             "invalid_operation",
             "invalid_stay",
             "invalid_stay",
             nil,
             "group_not_active",
             "group_not_active",
             "group_not_active",
             "group_not_found",
             "invalid_operation",
             "invalid_operation"
           ]

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 0, "status" => "cancelled"}} =
             json_response(get(conn, "/api/v1/groups/group-errors"), 200)
  end

  test "returns invalid batch and missing group errors", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => "not-a-list"}))

    assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

    assert %{"error" => %{"code" => "group_not_found"}} =
             json_response(get(build_conn(), "/api/v1/groups/missing"), 404)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } =
             json_response(get(build_conn(), "/api/v1/ledger"), 200)
  end

  test "fixes the policy at booking and recomputes its refundable date on reschedule", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("group-flex-14", %{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        open_operation("group-flex-30", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        open_operation("group-advance-policy", %{
          "occurred_on" => "2027-01-01",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        %{
          "operation_id" => "move-policy",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "group-flex-14",
          "new_arrival_on" => "2027-04-01"
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-18"
               }
             ]
           } = json_response(response, 200)

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-18",
               "arrival_on" => "2027-04-01"
             }
           } = json_response(get(conn, "/api/v1/groups/group-flex-14"), 200)

    assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-01-30"}} =
             json_response(get(conn, "/api/v1/groups/group-flex-30"), 200)

    assert %{"data" => %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil}} =
             json_response(get(conn, "/api/v1/groups/group-advance-policy"), 200)
  end

  test "issues, consumes, and restores hotel credit lots in expiry order", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("credit-source-a", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "pay-source-a",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "credit-source-a",
          "amount_cents" => 1_005
        },
        %{
          "operation_id" => "cancel-source-a",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => "credit-source-a",
          "refund_method" => "hotel_credit"
        },
        open_operation("credit-source-b", %{
          "occurred_on" => "2026-02-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "pay-source-b",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-02-02",
          "group_id" => "credit-source-b",
          "amount_cents" => 995
        },
        %{
          "operation_id" => "cancel-source-b",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-01",
          "group_id" => "credit-source-b",
          "refund_method" => "hotel_credit"
        },
        open_operation("credit-target", %{
          "occurred_on" => "2027-03-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-03-01",
          "group_id" => "credit-target",
          "amount_cents" => 1_500
        },
        %{
          "operation_id" => "cancel-target",
          "type" => "cancel_group",
          "occurred_on" => "2027-03-02",
          "group_id" => "credit-target"
        }
      ])

    assert %{"results" => results} = json_response(response, 200)
    assert Enum.at(results, 2)["credit_issued_cents"] == 1_106
    assert Enum.at(results, 5)["credit_issued_cents"] == 1_095
    assert Enum.at(results, 7)["revision"] == 2
    assert Enum.at(results, 8)["credit_issued_cents"] == 0

    assert %{
             "data" => %{
               "available_cents" => 2_201,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source-a",
                   "remaining_cents" => 1_106,
                   "expires_on" => "2028-01-01"
                 },
                 %{
                   "source_operation_id" => "cancel-source-b",
                   "remaining_cents" => 1_095,
                   "expires_on" => "2028-02-01"
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-03-01"), 200)

    assert %{
             "data" => %{
               "credit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "status" => "cancelled"
             }
           } = json_response(get(conn, "/api/v1/groups/credit-target"), 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 2_000,
               "credit_liability_cents" => 2_201
             }
           } = json_response(get(conn, "/api/v1/ledger?on=2027-03-01"), 200)
  end

  test "rejects hotel credit for non-refundable cancellation and consumes applied credit", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("nonref-source", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "pay-nonref-source",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "nonref-source",
          "amount_cents" => 1_000
        },
        %{
          "operation_id" => "cancel-nonref-source",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => "nonref-source",
          "refund_method" => "hotel_credit"
        },
        open_operation("nonref-target", %{
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "insufficient-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-02",
          "group_id" => "nonref-target",
          "amount_cents" => 1_200
        },
        %{
          "operation_id" => "apply-nonref-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-02",
          "group_id" => "nonref-target",
          "amount_cents" => 1_000
        },
        %{
          "operation_id" => "reject-credit-refund",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "nonref-target",
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "cancel-nonref-target",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "nonref-target"
        }
      ])

    assert %{"results" => results} = json_response(response, 200)
    assert Enum.at(results, 2)["credit_issued_cents"] == 1_100
    assert Enum.at(results, 4)["code"] == "insufficient_credit"
    assert Enum.at(results, 5)["revision"] == 2

    assert %{
             "code" => "refund_method_not_available",
             "operation_id" => "reject-credit-refund",
             "status" => "rejected"
           } = Enum.at(results, 6)

    assert Enum.at(results, 7)["retained_cents"] == 0

    assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} =
             json_response(get(conn, "/api/v1/groups/nonref-target"), 200)

    assert %{"data" => %{"available_cents" => 100}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-03"), 200)

    assert %{"data" => %{"credit_liability_cents" => 100}} =
             json_response(get(conn, "/api/v1/ledger?on=2027-01-03"), 200)
  end

  test "does not revive credit whose original expiry passed while it funded a group", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("expired-credit-source", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "pay-expired-source",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "expired-credit-source",
          "amount_cents" => 1_000
        },
        %{
          "operation_id" => "cancel-expired-source",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => "expired-credit-source",
          "refund_method" => "hotel_credit"
        },
        open_operation("expired-credit-target", %{
          "occurred_on" => "2027-01-03",
          "arrival_on" => "2028-02-05",
          "departure_on" => "2028-02-06",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        %{
          "operation_id" => "apply-expiring-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "expired-credit-target",
          "amount_cents" => 1_000
        },
        %{
          "operation_id" => "cancel-expired-target",
          "type" => "cancel_group",
          "occurred_on" => "2028-01-03",
          "group_id" => "expired-credit-target"
        }
      ])

    assert %{"results" => results} = json_response(response, 200)
    assert Enum.at(results, 5)["refunded_cents"] == 0
    assert Enum.at(results, 5)["retained_cents"] == 0

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2028-01-03"), 200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             json_response(get(conn, "/api/v1/ledger?on=2028-01-03"), 200)
  end

  test "replays an applied result without consulting current group state", %{conn: conn} do
    payment = %{
      "operation_id" => "durable-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "durable-group",
      "amount_cents" => 1_000,
      "expected_revision" => 1
    }

    assert %{"results" => [%{"status" => "applied"}, payment_result]} =
             json_response(
               submit(conn, [
                 open_operation("durable-group", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11"
                 }),
                 payment
               ]),
               200
             )

    assert payment_result == %{
             "operation_id" => "durable-payment",
             "status" => "applied",
             "group_id" => "durable-group",
             "amount_cents" => 1_000,
             "outstanding_deposit_cents" => 1_000,
             "revision" => 2
           }

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "durable-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "durable-group",
                   "expected_revision" => 2
                 }
               ]),
               200
             )

    reordered_payment = payment |> Map.to_list() |> Enum.reverse() |> Map.new()

    assert %{"results" => [replayed]} = json_response(submit(conn, [reordered_payment]), 200)
    assert replayed == payment_result

    assert %{"data" => stored_result} =
             json_response(get(conn, "/api/v1/operations/durable-payment"), 200)

    assert stored_result == payment_result

    assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} =
             json_response(get(conn, "/api/v1/groups/durable-group"), 200)
  end

  test "remembers handled rejections and rejects a different payload", %{conn: conn} do
    rejected_operation = %{
      "operation_id" => "durable-rejection",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "durable-rejection-group",
      "amount_cents" => 1
    }

    assert %{"results" => [%{"code" => "group_not_found"}]} =
             json_response(submit(conn, [rejected_operation]), 200)

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 open_operation("durable-rejection-group", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11"
                 })
               ]),
               200
             )

    assert %{"results" => [replayed]} = json_response(submit(conn, [rejected_operation]), 200)

    assert replayed == %{
             "operation_id" => "durable-rejection",
             "status" => "rejected",
             "code" => "group_not_found"
           }

    conflict = Map.put(rejected_operation, "amount_cents", 2)

    assert %{"results" => [conflict_result]} = json_response(submit(conn, [conflict]), 200)

    assert conflict_result == %{
             "operation_id" => "durable-rejection",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert %{"data" => stored_result} =
             json_response(get(conn, "/api/v1/operations/durable-rejection"), 200)

    assert stored_result == replayed

    records =
      GroupStay.Repo.all(GroupStay.Operations.Operation)
      |> Enum.sort_by(& &1.id)

    assert Enum.map(records, &{&1.operation_id, &1.type}) == [
             {"durable-rejection", "record_cash_payment"},
             {"open-durable-rejection-group", "open_group"}
           ]

    assert hd(records).payload == rejected_operation
  end

  test "returns operation_not_found for an unknown operation", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             json_response(get(conn, "/api/v1/operations/missing-operation"), 404)
  end

  test "treats array order as part of the operation payload", %{conn: conn} do
    operation = open_operation("array-payload")

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(submit(conn, [operation]), 200)

    changed_payload = Map.update!(operation, "rooms", &Enum.reverse/1)

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-array-payload",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = json_response(submit(conn, [changed_payload]), 200)
  end

  test "replays the original stale revision details", %{conn: conn} do
    stale = %{
      "operation_id" => "durable-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "durable-stale-group",
      "amount_cents" => 0,
      "expected_revision" => 0
    }

    assert %{"results" => [_, stale_result]} =
             json_response(
               submit(conn, [
                 open_operation("durable-stale-group", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11"
                 }),
                 stale
               ]),
               200
             )

    assert stale_result == %{
             "operation_id" => "durable-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "durable-stale-group",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert %{"results" => [%{"revision" => 2}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "durable-stale-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "durable-stale-group",
                   "amount_cents" => 1_000
                 }
               ]),
               200
             )

    assert %{"results" => [replayed]} = json_response(submit(conn, [stale]), 200)
    assert replayed == stale_result

    corrected = Map.put(stale, "expected_revision", 2)

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             json_response(submit(conn, [corrected]), 200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             json_response(get(conn, "/api/v1/groups/durable-stale-group"), 200)
  end

  test "concurrent retries apply an operation only once", %{conn: conn} do
    operation = open_operation("concurrent-group")

    results =
      1..8
      |> Task.async_stream(
        fn _ -> GroupStay.Operations.process_batch([operation]) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               "operation_id" => "open-concurrent-group",
               "status" => "applied",
               "group_id" => "concurrent-group",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    assert %{"data" => %{"revision" => 1, "status" => "active"}} =
             json_response(get(conn, "/api/v1/groups/concurrent-group"), 200)

    assert length(GroupStay.Repo.all(GroupStay.Operations.Operation)) == 1
  end
end
