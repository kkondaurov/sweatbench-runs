defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups.PartnerOperation
  alias GroupStay.Repo

  test "opens, funds, moves, and cancels a group while reporting its finance state", %{conn: conn} do
    open =
      open_group_operation("open-1", "group-1", "2026-10-03", %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
        ]
      })

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open]})

    assert %{"results" => [open_result]} = json_response(conn, 200)

    assert open_result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-1",
             "deposit_due_cents" => 19_502,
             "revision" => 1
           }

    conn =
      build_conn()
      |> post(~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 5_000,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "move-1",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-12-20",
            "expected_revision" => 2
          },
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-06",
            "group_id" => "group-1",
            "expected_revision" => 3
          }
        ]
      })

    assert %{"results" => results} = json_response(conn, 200)

    assert results == [
             %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_502,
               "revision" => 2
             },
             %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 3
             },
             %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 5_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/groups/group-1")

    assert %{"data" => group} = json_response(conn, 200)

    assert group == %{
             "group_id" => "group-1",
             "guest_id" => "guest-1",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-20",
             "departure_on" => "2026-12-23",
             "rate_plan" => "flexible",
             "status" => "cancelled",
             "revision" => 4,
             "rooms" => [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_001,
                 "status" => "cancelled",
                 "lodging_total_cents" => 45_003,
                 "deposit_due_cents" => 9_001,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_502,
                 "status" => "cancelled",
                 "lodging_total_cents" => 52_506,
                 "deposit_due_cents" => 10_501,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 0,
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-12-06",
             "outstanding_deposit_cents" => 0
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "keeps successful operations when a later operation is rejected", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-1", "group-1", "2026-10-03"),
          %{
            "operation_id" => "too-much",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 6_001
          },
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 6_000
          }
        ]
      })

    assert %{"results" => [open, rejected, payment]} = json_response(conn, 200)
    assert open["status"] == "applied"

    assert rejected == %{
             "operation_id" => "too-much",
             "status" => "rejected",
             "code" => "payment_exceeds_outstanding"
           }

    assert payment == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-1",
             "amount_cents" => 6_000,
             "outstanding_deposit_cents" => 0,
             "revision" => 2
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")
    assert json_response(conn, 200)["data"]["cash_held_cents"] == 6_000
  end

  test "checks group existence and revision before domain validation", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open_group_operation()]})
    assert json_response(conn, 200)["results"] |> hd() |> Map.fetch!("revision") == 1

    conn =
      build_conn()
      |> post(~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "not-a-date",
            "group_id" => "group-1",
            "amount_cents" => -1,
            "expected_revision" => 0
          },
          %{
            "operation_id" => "missing-group",
            "type" => "cancel_group",
            "occurred_on" => "not-a-date",
            "group_id" => "missing-group",
            "expected_revision" => 1
          }
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-pay",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           }
  end

  test "retains late flexible cash and always retains advance-purchase cash", %{conn: conn} do
    advance_purchase =
      open_group_operation("open-advance", "advance-group", "2026-10-03", %{
        "rate_plan" => "advance_purchase"
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-flex", "flex-group", "2026-10-03"),
          %{
            "operation_id" => "pay-flex",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "flex-group",
            "amount_cents" => 6_000
          },
          %{
            "operation_id" => "cancel-flex",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "flex-group"
          },
          advance_purchase,
          %{
            "operation_id" => "pay-advance",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "advance-group",
            "amount_cents" => 30_000
          },
          %{
            "operation_id" => "cancel-advance",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "advance-group"
          }
        ]
      })

    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.map(
             results,
             &Map.take(&1, ["operation_id", "status", "refunded_cents", "retained_cents"])
           ) == [
             %{"operation_id" => "open-flex", "status" => "applied"},
             %{"operation_id" => "pay-flex", "status" => "applied"},
             %{
               "operation_id" => "cancel-flex",
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 6_000
             },
             %{"operation_id" => "open-advance", "status" => "applied"},
             %{"operation_id" => "pay-advance", "status" => "applied"},
             %{
               "operation_id" => "cancel-advance",
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 30_000
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 36_000,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "returns stable validation errors and invalid batch responses", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/partner-batches", %{})
    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

    conn =
      build_conn()
      |> post(~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("bad-stay", "bad-stay", "2026-10-03", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          }),
          open_group_operation("bad-rooms", "bad-rooms", "2026-10-03", %{"rooms" => []}),
          open_group_operation("bad-plan", "bad-plan", "2026-10-03", %{"rate_plan" => "weekend"}),
          %{"operation_id" => "unknown", "type" => "dance", "occurred_on" => "2026-10-03"}
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{"operation_id" => "bad-stay", "status" => "rejected", "code" => "invalid_stay"},
             %{"operation_id" => "bad-rooms", "status" => "rejected", "code" => "invalid_rooms"},
             %{
               "operation_id" => "bad-plan",
               "status" => "rejected",
               "code" => "invalid_rate_plan"
             },
             %{"operation_id" => "unknown", "status" => "rejected", "code" => "invalid_operation"}
           ]

    conn = get(build_conn(), ~p"/api/v1/groups/no-such-group")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "fixes cancellation policy at opening and reports its rescheduled deadline", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-legacy", "legacy-window", "2026-12-31", %{
            "arrival_on" => "2027-03-01",
            "departure_on" => "2027-03-03"
          }),
          open_group_operation("open-new", "new-window", "2027-01-01", %{
            "arrival_on" => "2027-03-01",
            "departure_on" => "2027-03-03"
          }),
          open_group_operation("open-advance", "advance-window", "2027-01-01", %{
            "rate_plan" => "advance_purchase"
          })
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn = get(build_conn(), ~p"/api/v1/groups/legacy-window")

    assert json_response(conn, 200)["data"]
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-02-15"
           }

    conn = get(build_conn(), ~p"/api/v1/groups/new-window")

    assert json_response(conn, 200)["data"]
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "flex-30",
             "refundable_until" => "2027-01-30"
           }

    conn = get(build_conn(), ~p"/api/v1/groups/advance-window")

    assert json_response(conn, 200)["data"]
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "move-legacy",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-05",
            "group_id" => "legacy-window",
            "new_arrival_on" => "2027-04-10",
            "expected_revision" => 1
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "move-legacy",
               "status" => "applied",
               "group_id" => "legacy-window",
               "new_arrival_on" => "2027-04-10",
               "new_departure_on" => "2027-04-12",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-27",
               "revision" => 2
             }
           ]
  end

  test "converts a refundable cash deposit to credit and restores redeemed credit", %{conn: conn} do
    source =
      open_group_operation("open-source", "credit-source", "2026-11-01", %{
        "guest_id" => "guest-credit",
        "arrival_on" => "2027-01-20",
        "departure_on" => "2027-01-23"
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          source,
          %{
            "operation_id" => "pay-source",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-02",
            "group_id" => "credit-source",
            "amount_cents" => 1_001
          },
          %{
            "operation_id" => "cancel-source",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-06",
            "group_id" => "credit-source",
            "refund_method" => "hotel_credit"
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "cancel-source",
             "status" => "applied",
             "group_id" => "credit-source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 1_101,
             "revision" => 3
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-credit-funded", "credit-funded", "2026-11-02", %{
            "guest_id" => "guest-credit",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-04"
          }),
          %{
            "operation_id" => "apply-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-01-07",
            "group_id" => "credit-funded",
            "amount_cents" => 500,
            "expected_revision" => 1
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "apply-credit",
             "status" => "applied",
             "group_id" => "credit-funded",
             "amount_cents" => 500,
             "outstanding_deposit_cents" => 5_500,
             "revision" => 2
           }

    conn = get(build_conn(), ~p"/api/v1/groups/credit-funded")

    assert json_response(conn, 200)["data"]
           |> Map.take(["deposit_paid_cents", "cash_paid_cents", "credit_paid_cents"]) == %{
             "deposit_paid_cents" => 500,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 500
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "cancel-credit-funded",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-15",
            "group_id" => "credit-funded",
            "expected_revision" => 2
          }
        ]
      })

    assert json_response(conn, 200)["results"]
           |> hd()
           |> Map.take([
             "refunded_cents",
             "retained_cents",
             "credit_issued_cents",
             "revision"
           ]) == %{
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    conn = get(build_conn(), ~p"/api/v1/guests/guest-credit/credit?on=2027-01-15")

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-credit",
               "available_cents" => 1_101,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 1_101,
                   "expires_on" => "2028-01-07"
                 }
               ]
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2027-01-15")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_001,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 1_101,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "rejects credit on a non-refundable cancellation and consumes it when cancelled", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-source", "nonref-source", "2026-10-01", %{
            "guest_id" => "guest-nonref",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-23"
          }),
          %{
            "operation_id" => "pay-source",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "nonref-source",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "source-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-06",
            "group_id" => "nonref-source",
            "refund_method" => "hotel_credit"
          },
          open_group_operation("open-nonref", "nonref-target", "2026-10-03", %{
            "guest_id" => "guest-nonref",
            "rate_plan" => "advance_purchase",
            "arrival_on" => "2027-01-20",
            "departure_on" => "2027-01-23"
          }),
          %{
            "operation_id" => "apply-nonref-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-12-07",
            "group_id" => "nonref-target",
            "amount_cents" => 100,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "reject-nonref-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-07",
            "group_id" => "nonref-target",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          },
          %{
            "operation_id" => "cancel-nonref",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-07",
            "group_id" => "nonref-target",
            "expected_revision" => 2
          }
        ]
      })

    assert json_response(conn, 200)["results"]
           |> Enum.map(&Map.take(&1, ["operation_id", "status", "code", "revision"])) == [
             %{"operation_id" => "open-source", "status" => "applied", "revision" => 1},
             %{"operation_id" => "pay-source", "status" => "applied", "revision" => 2},
             %{"operation_id" => "source-credit", "status" => "applied", "revision" => 3},
             %{"operation_id" => "open-nonref", "status" => "applied", "revision" => 1},
             %{"operation_id" => "apply-nonref-credit", "status" => "applied", "revision" => 2},
             %{
               "operation_id" => "reject-nonref-credit",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             },
             %{"operation_id" => "cancel-nonref", "status" => "applied", "revision" => 3}
           ]

    conn = get(build_conn(), ~p"/api/v1/guests/guest-nonref/credit?on=2026-12-07")

    assert json_response(conn, 200)["data"] == %{
             "guest_id" => "guest-nonref",
             "available_cents" => 10,
             "lots" => [
               %{
                 "source_operation_id" => "source-credit",
                 "remaining_cents" => 10,
                 "expires_on" => "2027-12-07"
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2026-12-07")
    assert json_response(conn, 200)["data"]["credit_liability_cents"] == 10
  end

  test "uses credit lots by expiry and operation id, and expires a late restoration", %{
    conn: conn
  } do
    source = fn operation_id, group_id, amount_cents ->
      [
        open_group_operation("open-#{group_id}", group_id, "2026-12-01", %{
          "guest_id" => "guest-order",
          "arrival_on" => "2027-02-01",
          "departure_on" => "2027-02-04"
        }),
        %{
          "operation_id" => "pay-#{group_id}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-12-02",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        },
        %{
          "operation_id" => operation_id,
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        }
      ]
    end

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" =>
          source.("source-z", "order-source-z", 100) ++
            source.("source-a", "order-source-a", 200) ++
            [
              open_group_operation("open-order-target", "order-target", "2026-12-02", %{
                "guest_id" => "guest-order",
                "arrival_on" => "2027-03-01",
                "departure_on" => "2027-03-04"
              }),
              %{
                "operation_id" => "apply-ordered-credit",
                "type" => "apply_hotel_credit",
                "occurred_on" => "2027-01-02",
                "group_id" => "order-target",
                "amount_cents" => 150
              }
            ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn = get(build_conn(), ~p"/api/v1/guests/guest-order/credit?on=2027-01-02")

    assert json_response(conn, 200)["data"]["lots"] == [
             %{
               "source_operation_id" => "source-a",
               "remaining_cents" => 70,
               "expires_on" => "2028-01-02"
             },
             %{
               "source_operation_id" => "source-z",
               "remaining_cents" => 110,
               "expires_on" => "2028-01-02"
             }
           ]

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-expiring", "expiring-target", "2026-12-03", %{
            "guest_id" => "guest-order",
            "arrival_on" => "2028-02-15",
            "departure_on" => "2028-02-18"
          }),
          %{
            "operation_id" => "apply-expiring-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2028-01-01",
            "group_id" => "expiring-target",
            "amount_cents" => 70
          },
          %{
            "operation_id" => "cancel-expiring",
            "type" => "cancel_group",
            "occurred_on" => "2028-01-02",
            "group_id" => "expiring-target"
          }
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn = get(build_conn(), ~p"/api/v1/guests/guest-order/credit?on=2028-01-01")
    assert json_response(conn, 200)["data"]["available_cents"] == 110

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2028-01-01")
    assert json_response(conn, 200)["data"]["credit_liability_cents"] == 260

    conn = get(build_conn(), ~p"/api/v1/guests/guest-order/credit?on=2028-01-02")
    assert json_response(conn, 200)["data"]["available_cents"] == 0

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2028-01-02")
    assert json_response(conn, 200)["data"]["credit_liability_cents"] == 150
  end

  test "durably replays an equivalent operation without revisiting current group state", %{
    conn: conn
  } do
    open = open_group_operation("durable-open", "durable-group")

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open]})
    assert %{"results" => [open_result]} = json_response(conn, 200)

    reordered_open = open |> Map.to_list() |> Enum.reverse() |> Map.new()

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [reordered_open]})

    assert json_response(conn, 200) == %{"results" => [open_result]}

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "durable-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "durable-group",
            "amount_cents" => 500,
            "expected_revision" => 1
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "durable-payment",
               "status" => "applied",
               "group_id" => "durable-group",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 5_500,
               "revision" => 2
             }
           ]

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [open]})
    assert json_response(conn, 200) == %{"results" => [open_result]}

    conn = get(build_conn(), ~p"/api/v1/operations/durable-open")
    assert json_response(conn, 200) == %{"data" => open_result}

    assert %PartnerOperation{} =
             stored = Repo.get_by(PartnerOperation, operation_id: "durable-open")

    assert stored.operation_type == "open_group"
    assert Jason.decode!(stored.submission_json) == open

    conflicting_open = Map.put(open, "property_id", "rtm-center")

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          conflicting_open,
          %{
            "operation_id" => "later-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "durable-group",
            "amount_cents" => 200,
            "expected_revision" => 2
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "durable-open",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             },
             %{
               "operation_id" => "later-payment",
               "status" => "applied",
               "group_id" => "durable-group",
               "amount_cents" => 200,
               "outstanding_deposit_cents" => 5_300,
               "revision" => 3
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/groups/durable-group")

    assert json_response(conn, 200)["data"]
           |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 700,
             "revision" => 3
           }

    conn = get(build_conn(), ~p"/api/v1/operations/no-such-operation")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "remembers rejected operations even if later operations would make them valid", %{
    conn: conn
  } do
    payment_before_open = %{
      "operation_id" => "payment-before-open",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "eventual-group",
      "amount_cents" => 500
    }

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [payment_before_open]})

    assert %{"results" => [rejected_result]} = json_response(conn, 200)

    assert rejected_result == %{
             "operation_id" => "payment-before-open",
             "status" => "rejected",
             "code" => "group_not_found"
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-eventual", "eventual-group"),
          payment_before_open
        ]
      })

    assert [open_result, ^rejected_result] = json_response(conn, 200)["results"]
    assert open_result["status"] == "applied"

    conn = get(build_conn(), ~p"/api/v1/groups/eventual-group")

    assert json_response(conn, 200)["data"]
           |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 0,
             "revision" => 1
           }

    conn = get(build_conn(), ~p"/api/v1/operations/payment-before-open")
    assert json_response(conn, 200) == %{"data" => rejected_result}
  end

  test "replays the original stale revision details and rejects a corrected retry as a conflict",
       %{
         conn: conn
       } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [open_group_operation("open-stale", "stale-group")]
      })

    assert json_response(conn, 200)["results"] |> hd() |> Map.fetch!("revision") == 1

    stale_payment = %{
      "operation_id" => "stale-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "stale-group",
      "amount_cents" => 100,
      "expected_revision" => 0
    }

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [stale_payment]})
    assert %{"results" => [stale_result]} = json_response(conn, 200)

    assert stale_result == %{
             "operation_id" => "stale-payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "stale-group",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    valid_payment =
      Map.put(stale_payment, "operation_id", "valid-payment") |> Map.put("expected_revision", 1)

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [valid_payment]})
    assert json_response(conn, 200)["results"] |> hd() |> Map.fetch!("revision") == 2

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [stale_payment]})
    assert json_response(conn, 200) == %{"results" => [stale_result]}

    corrected_retry = Map.put(stale_payment, "expected_revision", 2)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [corrected_retry]})

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }
  end

  test "remembers malformed operations that still have an operation identifier", %{conn: conn} do
    malformed = %{"operation_id" => "malformed-operation", "type" => ""}

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [malformed]})

    assert %{"results" => [result]} = json_response(conn, 200)

    assert result == %{
             "operation_id" => "malformed-operation",
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    conn = get(build_conn(), ~p"/api/v1/operations/malformed-operation")
    assert json_response(conn, 200) == %{"data" => result}

    assert Repo.get_by(PartnerOperation, operation_id: "malformed-operation").operation_type == ""
  end

  test "accounts for rooms independently and settles only selected active rooms", %{conn: conn} do
    open =
      open_group_operation("open-room-accounting", "room-accounting", "2026-10-01", %{
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 1_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 2_000}
        ],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12"
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open,
          %{
            "operation_id" => "pay-room-accounting",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "room-accounting",
            "amount_cents" => 700
          },
          %{
            "operation_id" => "cancel-room-b",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-03",
            "group_id" => "room-accounting",
            "room_ids" => ["room-b"]
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "cancel-room-b",
             "status" => "applied",
             "group_id" => "room-accounting",
             "cancelled_room_ids" => ["room-b"],
             "refunded_cents" => 300,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    conn = get(build_conn(), ~p"/api/v1/groups/room-accounting")

    assert json_response(conn, 200)["data"]
           |> Map.take([
             "status",
             "lodging_total_cents",
             "deposit_due_cents",
             "deposit_paid_cents",
             "cash_paid_cents",
             "outstanding_deposit_cents",
             "revision",
             "rooms"
           ]) == %{
             "status" => "active",
             "lodging_total_cents" => 2_000,
             "deposit_due_cents" => 400,
             "deposit_paid_cents" => 400,
             "cash_paid_cents" => 400,
             "outstanding_deposit_cents" => 0,
             "revision" => 3,
             "rooms" => [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 1_000,
                 "status" => "active",
                 "lodging_total_cents" => 2_000,
                 "deposit_due_cents" => 400,
                 "cash_paid_cents" => 400,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 2_000,
                 "status" => "cancelled",
                 "lodging_total_cents" => 4_000,
                 "deposit_due_cents" => 800,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "bad-room-cancellation",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-03",
            "group_id" => "room-accounting",
            "room_ids" => ["room-b", "room-b"],
            "expected_revision" => 3
          },
          %{
            "operation_id" => "cancel-last-room",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-03",
            "group_id" => "room-accounting",
            "room_ids" => ["room-a"],
            "expected_revision" => 3
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "bad-room-cancellation",
               "status" => "rejected",
               "code" => "invalid_rooms"
             },
             %{
               "operation_id" => "cancel-last-room",
               "status" => "applied",
               "group_id" => "room-accounting",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 400,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }
           ]
  end

  test "reduces one payment's held cash in reverse allocation order and reconciles it", %{
    conn: conn
  } do
    open =
      open_group_operation("open-reduction", "reduction-group", "2026-10-01", %{
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 1_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 2_000}
        ],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12"
      })

    pay_one = %{
      "operation_id" => "pay-one",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => "reduction-group",
      "amount_cents" => 1_000
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open,
          pay_one,
          %{
            "operation_id" => "pay-two",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "reduction-group",
            "amount_cents" => 200
          },
          %{
            "operation_id" => "reduce-pay-one",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "pay-one",
            "amount_cents" => 500,
            "expected_revision" => 3
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "reduce-pay-one",
             "status" => "applied",
             "payment_operation_id" => "pay-one",
             "group_id" => "reduction-group",
             "amount_cents" => 500,
             "outstanding_deposit_cents" => 500,
             "revision" => 4
           }

    conn = get(build_conn(), ~p"/api/v1/groups/reduction-group")

    assert json_response(conn, 200)["data"]
           |> Map.take([
             "cash_paid_cents",
             "deposit_paid_cents",
             "outstanding_deposit_cents",
             "rooms"
           ]) ==
             %{
               "cash_paid_cents" => 700,
               "deposit_paid_cents" => 700,
               "outstanding_deposit_cents" => 500,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 1_000,
                   "status" => "active",
                   "lodging_total_cents" => 2_000,
                   "deposit_due_cents" => 400,
                   "cash_paid_cents" => 400,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 2_000,
                   "status" => "active",
                   "lodging_total_cents" => 4_000,
                   "deposit_due_cents" => 800,
                   "cash_paid_cents" => 300,
                   "credit_paid_cents" => 0
                 }
               ]
             }

    conn = get(build_conn(), ~p"/api/v1/payments/pay-one")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-one",
               "original_group_id" => "reduction-group",
               "recorded_cents" => 1_000,
               "held_cents" => 500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 0
             }
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "over-reduce-pay-one",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "pay-one",
            "amount_cents" => 600,
            "expected_revision" => 4
          },
          pay_one
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "over-reduce-pay-one",
               "status" => "rejected",
               "code" => "reduction_exceeds_held_cash"
             },
             %{
               "operation_id" => "pay-one",
               "status" => "applied",
               "group_id" => "reduction-group",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 200,
               "revision" => 2
             }
           ]
  end

  test "chargebacks move converted payment cash and absorb its shortfall on restoration", %{
    conn: conn
  } do
    source =
      open_group_operation("open-charge-source", "charge-source", "2026-10-01", %{
        "guest_id" => "guest-charge"
      })

    target =
      open_group_operation("open-charge-target", "charge-target", "2026-10-01", %{
        "guest_id" => "guest-charge"
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          source,
          %{
            "operation_id" => "pay-charge-a",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "charge-source",
            "amount_cents" => 200
          },
          %{
            "operation_id" => "pay-charge-b",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "charge-source",
            "amount_cents" => 300
          },
          %{
            "operation_id" => "convert-charge-source",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "charge-source",
            "refund_method" => "hotel_credit"
          },
          target,
          %{
            "operation_id" => "apply-charge-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "charge-target",
            "amount_cents" => 550
          },
          %{
            "operation_id" => "charge-back-b",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-charge-b",
            "expected_revision" => 4
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "charge-back-b",
             "status" => "applied",
             "payment_operation_id" => "pay-charge-b",
             "group_id" => "charge-source",
             "charged_back_cents" => 300,
             "outstanding_deposit_cents" => 0,
             "revision" => 5
           }

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2026-10-04")

    assert json_response(conn, 200)["data"]
           |> Map.take([
             "cash_converted_to_credit_cents",
             "cash_charged_back_cents",
             "credit_liability_cents",
             "credit_shortfall_cents"
           ]) == %{
             "cash_converted_to_credit_cents" => 200,
             "cash_charged_back_cents" => 300,
             "credit_liability_cents" => 550,
             "credit_shortfall_cents" => 330
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "cancel-charge-target",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "charge-target",
            "expected_revision" => 2
          },
          %{
            "operation_id" => "repeat-charge-back-b",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-charge-b",
            "expected_revision" => 5
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "cancel-charge-target",
               "status" => "applied",
               "group_id" => "charge-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             },
             %{
               "operation_id" => "repeat-charge-back-b",
               "status" => "rejected",
               "code" => "payment_not_chargeable"
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/guests/guest-charge/credit?on=2026-10-05")
    assert json_response(conn, 200)["data"]["available_cents"] == 220

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2026-10-05")

    assert json_response(conn, 200)["data"]
           |> Map.take(["credit_liability_cents", "credit_shortfall_cents"]) == %{
             "credit_liability_cents" => 220,
             "credit_shortfall_cents" => 0
           }

    conn = get(build_conn(), ~p"/api/v1/payments/pay-charge-b")

    assert json_response(conn, 200)["data"]
           |> Map.take(["recorded_cents", "converted_to_credit_cents", "charged_back_cents"]) ==
             %{
               "recorded_cents" => 300,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 300
             }

    conn = get(build_conn(), ~p"/api/v1/payments/open-charge-source")
    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "transfers mixed held funding with its provenance and settles it under the destination policy",
       %{
         conn: conn
       } do
    credit_source =
      open_group_operation("open-transfer-credit", "transfer-credit", "2026-10-01", %{
        "guest_id" => "guest-transfer"
      })

    source =
      open_group_operation("open-transfer-source", "transfer-source", "2026-10-01", %{
        "guest_id" => "guest-transfer"
      })

    destination =
      open_group_operation("open-transfer-destination", "transfer-destination", "2026-10-01", %{
        "guest_id" => "guest-transfer",
        "rooms" => [
          %{"room_id" => "destination-a", "nightly_rate_cents" => 5_000},
          %{"room_id" => "destination-b", "nightly_rate_cents" => 5_000}
        ]
      })

    transfer = %{
      "operation_id" => "transfer-mixed-funding",
      "type" => "transfer_deposit",
      "source_group_id" => "transfer-source",
      "destination_group_id" => "transfer-destination",
      "amount_cents" => 1_000,
      "expected_revision" => 4,
      "destination_expected_revision" => 1
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          credit_source,
          %{
            "operation_id" => "pay-transfer-credit",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "transfer-credit",
            "amount_cents" => 1_000
          },
          %{
            "operation_id" => "convert-transfer-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "transfer-credit",
            "refund_method" => "hotel_credit"
          },
          source,
          %{
            "operation_id" => "pay-transfer-a",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "transfer-source",
            "amount_cents" => 600
          },
          %{
            "operation_id" => "apply-transfer-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "transfer-source",
            "amount_cents" => 500
          },
          %{
            "operation_id" => "pay-transfer-b",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "transfer-source",
            "amount_cents" => 400
          },
          destination,
          transfer
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "transfer-mixed-funding",
             "status" => "applied",
             "source_group_id" => "transfer-source",
             "destination_group_id" => "transfer-destination",
             "amount_cents" => 1_000,
             "source_outstanding_deposit_cents" => 5_500,
             "destination_outstanding_deposit_cents" => 5_000,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    conn = get(build_conn(), ~p"/api/v1/groups/transfer-source")

    assert json_response(conn, 200)["data"]
           |> Map.take(["cash_paid_cents", "credit_paid_cents", "deposit_paid_cents", "revision"]) ==
             %{
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 0,
               "deposit_paid_cents" => 500,
               "revision" => 5
             }

    conn = get(build_conn(), ~p"/api/v1/groups/transfer-destination")

    assert json_response(conn, 200)["data"]
           |> Map.take([
             "cash_paid_cents",
             "credit_paid_cents",
             "deposit_paid_cents",
             "revision",
             "rooms"
           ]) ==
             %{
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 500,
               "deposit_paid_cents" => 1_000,
               "revision" => 2,
               "rooms" => [
                 %{
                   "room_id" => "destination-a",
                   "nightly_rate_cents" => 5_000,
                   "status" => "active",
                   "lodging_total_cents" => 15_000,
                   "deposit_due_cents" => 3_000,
                   "cash_paid_cents" => 500,
                   "credit_paid_cents" => 500
                 },
                 %{
                   "room_id" => "destination-b",
                   "nightly_rate_cents" => 5_000,
                   "status" => "active",
                   "lodging_total_cents" => 15_000,
                   "deposit_due_cents" => 3_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ]
             }

    conn = get(build_conn(), ~p"/api/v1/payments/pay-transfer-a")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-transfer-a",
               "original_group_id" => "transfer-source",
               "recorded_cents" => 600,
               "held_cents" => 600,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "transfer-destination", "amount_cents" => 100},
                 %{"group_id" => "transfer-source", "amount_cents" => 500}
               ]
             }
           }

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [transfer]})

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "transfer-mixed-funding",
               "status" => "applied",
               "source_group_id" => "transfer-source",
               "destination_group_id" => "transfer-destination",
               "amount_cents" => 1_000,
               "source_outstanding_deposit_cents" => 5_500,
               "destination_outstanding_deposit_cents" => 5_000,
               "source_revision" => 5,
               "destination_revision" => 2
             }
           ]

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "cancel-transfer-destination",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "transfer-destination",
            "expected_revision" => 2
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "cancel-transfer-destination",
               "status" => "applied",
               "group_id" => "transfer-destination",
               "refunded_cents" => 500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/payments/pay-transfer-a")

    assert json_response(conn, 200)["data"]
           |> Map.take(["held_cents", "refunded_cents", "held_by_group"]) ==
             %{
               "held_cents" => 500,
               "refunded_cents" => 100,
               "held_by_group" => [%{"group_id" => "transfer-source", "amount_cents" => 500}]
             }

    conn = get(build_conn(), ~p"/api/v1/guests/guest-transfer/credit?on=2026-10-05")
    assert json_response(conn, 200)["data"]["available_cents"] == 1_100
  end

  test "validates transfer identities, group lookup, and both revision guards before transfer rules",
       %{
         conn: conn
       } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-transfer-one", "transfer-one", "2026-10-01"),
          open_group_operation("open-transfer-other", "transfer-other", "2026-10-01", %{
            "guest_id" => "other-guest"
          })
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "type" => "transfer_deposit",
            "source_group_id" => "transfer-one",
            "destination_group_id" => "transfer-other",
            "amount_cents" => 1
          },
          %{
            "operation_id" => "missing-transfer-source",
            "type" => "transfer_deposit",
            "source_group_id" => "missing-source",
            "destination_group_id" => "transfer-one",
            "amount_cents" => -1
          },
          %{
            "operation_id" => "missing-transfer-destination",
            "type" => "transfer_deposit",
            "source_group_id" => "transfer-one",
            "destination_group_id" => "missing-destination",
            "amount_cents" => -1
          },
          %{
            "operation_id" => "stale-transfer-source",
            "type" => "transfer_deposit",
            "source_group_id" => "transfer-one",
            "destination_group_id" => "transfer-one",
            "amount_cents" => -1,
            "expected_revision" => 0
          },
          %{
            "operation_id" => "stale-transfer-destination",
            "type" => "transfer_deposit",
            "source_group_id" => "transfer-one",
            "destination_group_id" => "transfer-other",
            "amount_cents" => -1,
            "expected_revision" => 1,
            "destination_expected_revision" => 0
          },
          %{
            "operation_id" => "invalid-transfer-guests",
            "type" => "transfer_deposit",
            "source_group_id" => "transfer-one",
            "destination_group_id" => "transfer-other",
            "amount_cents" => -1,
            "expected_revision" => 1,
            "destination_expected_revision" => 1
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             },
             %{
               "operation_id" => "missing-transfer-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "missing-source"
             },
             %{
               "operation_id" => "missing-transfer-destination",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "missing-destination"
             },
             %{
               "operation_id" => "stale-transfer-source",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "transfer-one",
               "expected_revision" => 0,
               "actual_revision" => 1
             },
             %{
               "operation_id" => "stale-transfer-destination",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "transfer-other",
               "expected_revision" => 0,
               "actual_revision" => 1
             },
             %{
               "operation_id" => "invalid-transfer-guests",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }
           ]
  end

  test "reductions and chargebacks follow transferred payment allocations and revise every changed group",
       %{
         conn: conn
       } do
    source =
      open_group_operation("open-correction-source", "correction-source", "2026-10-01", %{
        "guest_id" => "guest-correction"
      })

    destination =
      open_group_operation(
        "open-correction-destination",
        "correction-destination",
        "2026-10-01",
        %{
          "guest_id" => "guest-correction"
        }
      )

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          source,
          %{
            "operation_id" => "pay-correction",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-02",
            "group_id" => "correction-source",
            "amount_cents" => 1_000
          },
          destination,
          %{
            "operation_id" => "transfer-correction",
            "type" => "transfer_deposit",
            "source_group_id" => "correction-source",
            "destination_group_id" => "correction-destination",
            "amount_cents" => 1_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          },
          %{
            "operation_id" => "reduce-transferred-payment",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "pay-correction",
            "amount_cents" => 400,
            "expected_revision" => 3
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> List.last() == %{
             "operation_id" => "reduce-transferred-payment",
             "status" => "applied",
             "payment_operation_id" => "pay-correction",
             "group_id" => "correction-source",
             "amount_cents" => 400,
             "outstanding_deposit_cents" => 6_000,
             "revision" => 4
           }

    conn = get(build_conn(), ~p"/api/v1/groups/correction-destination")

    assert json_response(conn, 200)["data"]
           |> Map.take(["deposit_paid_cents", "outstanding_deposit_cents", "revision"]) ==
             %{
               "deposit_paid_cents" => 600,
               "outstanding_deposit_cents" => 5_400,
               "revision" => 3
             }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "charge-back-transferred-payment",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-correction",
            "expected_revision" => 4
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "charge-back-transferred-payment",
               "status" => "applied",
               "payment_operation_id" => "pay-correction",
               "group_id" => "correction-source",
               "charged_back_cents" => 600,
               "outstanding_deposit_cents" => 6_000,
               "revision" => 5
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/groups/correction-destination")

    assert json_response(conn, 200)["data"]
           |> Map.take(["deposit_paid_cents", "outstanding_deposit_cents", "revision"]) ==
             %{
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 6_000,
               "revision" => 4
             }

    conn = get(build_conn(), ~p"/api/v1/payments/pay-correction")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-correction",
               "original_group_id" => "correction-source",
               "recorded_cents" => 1_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 400,
               "charged_back_cents" => 600,
               "held_by_group" => []
             }
           }
  end

  defp open_group_operation(
         operation_id \\ "open-1",
         group_id \\ "group-1",
         occurred_on \\ "2026-10-03",
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end
end
