defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "opens a flexible group and exposes it through reads", %{conn: conn} do
      open_group = %{
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
      }

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open_group]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")

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
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             }

      conn = get(build_conn(), ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "applies payments, reschedules, and refundable cancellation in batch order", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("group-sequence"),
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-sequence",
              "amount_cents" => 4_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-move",
              "type" => "reschedule_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-sequence",
              "new_arrival_on" => "2026-12-20",
              "expected_revision" => 2
            },
            %{
              "operation_id" => "op-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-12-01",
              "group_id" => "group-sequence",
              "expected_revision" => 3
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open-group-sequence",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "deposit_due_cents" => 10_000,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "amount_cents" => 4_000,
                   "outstanding_deposit_cents" => 6_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-22",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-06",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "refunded_cents" => 4_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             }

      assert %{
               "data" => %{
                 "revision" => 4,
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-22",
                 "status" => "cancelled",
                 "deposit_paid_cents" => 4_000,
                 "cash_paid_cents" => 4_000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-sequence") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 4_000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "retains advance-purchase payments on cancellation", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-open-advance",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "group-advance",
              "guest_id" => "guest-advance",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-12",
              "rate_plan" => "advance_purchase",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 12_000}
              ]
            },
            %{
              "operation_id" => "op-pay-advance",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-advance",
              "amount_cents" => 24_000
            },
            %{
              "operation_id" => "op-cancel-advance",
              "type" => "cancel_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-advance"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"deposit_due_cents" => 24_000, "revision" => 1},
                 %{"outstanding_deposit_cents" => 0, "revision" => 2},
                 %{"refunded_cents" => 0, "retained_cents" => 24_000, "revision" => 3}
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 24_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "rounds flexible deposits per room before summing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-rounding",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "group-rounding",
              "guest_id" => "guest-rounding",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rate_plan" => "flexible",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 3},
                %{"room_id" => "room-b", "nightly_rate_cents" => 3}
              ]
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-rounding",
                   "status" => "applied",
                   "group_id" => "group-rounding",
                   "deposit_due_cents" => 2,
                   "revision" => 1
                 }
               ]
             }
    end

    test "assigns policy versions from booking date and keeps them fixed on reschedule", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("policy-legacy", %{
              "occurred_on" => "2026-12-31",
              "arrival_on" => "2027-02-10",
              "departure_on" => "2027-02-12"
            }),
            flexible_open("policy-new", %{
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-10",
              "departure_on" => "2027-03-12"
            }),
            %{
              "operation_id" => "op-move-policy-new",
              "type" => "reschedule_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "policy-new",
              "new_arrival_on" => "2027-03-20",
              "expected_revision" => 1
            }
          ]
        })

      assert %{
               "results" => [
                 %{"group_id" => "policy-legacy", "revision" => 1},
                 %{"group_id" => "policy-new", "revision" => 1},
                 %{
                   "group_id" => "policy-new",
                   "policy_version" => "flex-30",
                   "refundable_until" => "2027-02-18",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-01-27"
               }
             } = get(build_conn(), ~p"/api/v1/groups/policy-legacy") |> json_response(200)

      assert %{
               "data" => %{
                 "arrival_on" => "2027-03-20",
                 "departure_on" => "2027-03-22",
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-02-18"
               }
             } = get(build_conn(), ~p"/api/v1/groups/policy-new") |> json_response(200)
    end

    test "issues boosted hotel credit for refundable cancellations and reports expiry", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("credit-source", %{
              "guest_id" => "guest-credit",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22"
            }),
            cash_payment("credit-source", 5_005, %{
              "operation_id" => "pay-credit-source",
              "expected_revision" => 1
            }),
            cancel("credit-source", %{
              "operation_id" => "cancel-credit-source",
              "occurred_on" => "2026-12-01",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"outstanding_deposit_cents" => 4_995, "revision" => 2},
                 %{
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 5_506,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/ledger?on=2026-12-01") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 5_005,
                 "credit_liability_cents" => 5_506
               }
             }

      assert get(build_conn(), ~p"/api/v1/guests/guest-credit/credit?on=2027-12-01")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => "guest-credit",
                 "available_cents" => 5_506,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-credit-source",
                     "remaining_cents" => 5_506,
                     "expires_on" => "2027-12-02"
                   }
                 ]
               }
             }

      assert get(build_conn(), ~p"/api/v1/guests/guest-credit/credit?on=2027-12-02")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => "guest-credit",
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      assert get(build_conn(), ~p"/api/v1/ledger?on=2027-12-02") |> json_response(200) ==
               %{
                 "data" => %{
                   "cash_held_cents" => 0,
                   "cash_refunded_cents" => 0,
                   "cash_retained_cents" => 0,
                   "cash_converted_to_credit_cents" => 5_005,
                   "credit_liability_cents" => 0
                 }
               }
    end

    test "applies credit by lot order and restores unexpired lots on refundable cancellation", %{
      conn: conn
    } do
      guest_id = "guest-lots"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("source-a", %{
              "operation_id" => "open-source-a",
              "guest_id" => guest_id,
              "occurred_on" => "2025-12-01",
              "arrival_on" => "2026-03-01",
              "departure_on" => "2026-03-03"
            }),
            cash_payment("source-a", 1_000, %{
              "operation_id" => "pay-source-a",
              "occurred_on" => "2025-12-02"
            }),
            cancel("source-a", %{
              "operation_id" => "cancel-a",
              "occurred_on" => "2026-01-01",
              "refund_method" => "hotel_credit"
            }),
            flexible_open("source-b", %{
              "operation_id" => "open-source-b",
              "guest_id" => guest_id,
              "occurred_on" => "2025-12-01",
              "arrival_on" => "2026-03-01",
              "departure_on" => "2026-03-03"
            }),
            cash_payment("source-b", 1_000, %{
              "operation_id" => "pay-source-b",
              "occurred_on" => "2025-12-02"
            }),
            cancel("source-b", %{
              "operation_id" => "cancel-b",
              "occurred_on" => "2026-01-01",
              "refund_method" => "hotel_credit"
            }),
            flexible_open("credit-target", %{
              "guest_id" => guest_id,
              "occurred_on" => "2026-01-03",
              "arrival_on" => "2026-04-01",
              "departure_on" => "2026-04-03"
            }),
            apply_credit("credit-target", 1_500, %{
              "operation_id" => "apply-target-credit",
              "occurred_on" => "2026-01-04",
              "expected_revision" => 1
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"credit_issued_cents" => 1_100, "revision" => 3},
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"credit_issued_cents" => 1_100, "revision" => 3},
                 %{"revision" => 1},
                 %{"outstanding_deposit_cents" => 8_500, "revision" => 2}
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit?on=2026-01-04")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => guest_id,
                 "available_cents" => 700,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 700,
                     "expires_on" => "2027-01-02"
                   }
                 ]
               }
             }

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 1_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1_500,
                 "outstanding_deposit_cents" => 8_500,
                 "revision" => 2
               }
             } = get(build_conn(), ~p"/api/v1/groups/credit-target") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/ledger?on=2026-01-04") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 2_000,
                 "credit_liability_cents" => 2_200
               }
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            cancel("credit-target", %{
              "operation_id" => "cancel-target",
              "occurred_on" => "2026-01-05",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit?on=2026-01-05")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => guest_id,
                 "available_cents" => 2_200,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2027-01-02"
                   },
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2027-01-02"
                   }
                 ]
               }
             }
    end

    test "does not restore applied credit whose original expiry has passed", %{conn: conn} do
      guest_id = "guest-expired-restore"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("expired-source", %{
              "guest_id" => guest_id,
              "occurred_on" => "2025-12-01",
              "arrival_on" => "2026-03-01",
              "departure_on" => "2026-03-03"
            }),
            cash_payment("expired-source", 1_000, %{"occurred_on" => "2025-12-02"}),
            cancel("expired-source", %{
              "operation_id" => "cancel-expired-source",
              "occurred_on" => "2026-01-01",
              "refund_method" => "hotel_credit"
            }),
            flexible_open("expired-target", %{
              "guest_id" => guest_id,
              "occurred_on" => "2026-01-02",
              "arrival_on" => "2027-02-15",
              "departure_on" => "2027-02-17"
            }),
            apply_credit("expired-target", 1_100, %{
              "occurred_on" => "2026-01-03",
              "expected_revision" => 1
            }),
            cancel("expired-target", %{
              "occurred_on" => "2027-01-03",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"credit_issued_cents" => 1_100, "revision" => 3},
                 %{"revision" => 1},
                 %{"outstanding_deposit_cents" => 8_900, "revision" => 2},
                 %{
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit?on=2027-01-03")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => guest_id,
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      assert get(build_conn(), ~p"/api/v1/ledger?on=2027-01-03") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 1_000,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "rejects hotel credit refund for non-refundable cancellations and leaves group active",
         %{
           conn: conn
         } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("new-window", %{
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-10",
              "departure_on" => "2027-03-12"
            }),
            cash_payment("new-window", 1_000, %{
              "occurred_on" => "2027-01-02",
              "expected_revision" => 1
            }),
            cancel("new-window", %{
              "operation_id" => "cancel-new-window-credit",
              "occurred_on" => "2027-02-15",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{
                   "operation_id" => "cancel-new-window-credit",
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "active",
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-02-08",
                 "cash_paid_cents" => 1_000,
                 "revision" => 2
               }
             } = get(build_conn(), ~p"/api/v1/groups/new-window") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/ledger?on=2027-02-15") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 1_000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            cancel("new-window", %{
              "operation_id" => "cancel-new-window-cash",
              "occurred_on" => "2027-02-15",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-new-window-cash",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 1_000,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/ledger?on=2027-02-15") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 1_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "rejects hotel credit application errors without advancing revision", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("credit-errors"),
            apply_credit("credit-errors", 100, %{
              "operation_id" => "credit-stale",
              "expected_revision" => 0
            }),
            apply_credit("credit-errors", 0, %{"operation_id" => "credit-bad-amount"}),
            apply_credit("credit-errors", 10_001, %{"operation_id" => "credit-too-much"}),
            apply_credit("credit-errors", 100, %{"operation_id" => "credit-insufficient"})
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{
                   "operation_id" => "credit-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{
                   "operation_id" => "credit-bad-amount",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "credit-too-much",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{
                   "operation_id" => "credit-insufficient",
                   "status" => "rejected",
                   "code" => "insufficient_credit"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "revision" => 1
               }
             } = get(build_conn(), ~p"/api/v1/groups/credit-errors") |> json_response(200)
    end

    test "rejects stale revisions before domain validation and keeps processing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("group-revisions"),
            %{
              "operation_id" => "op-first-payment",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-revisions",
              "amount_cents" => 2_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-stale-invalid",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-revisions",
              "amount_cents" => -100,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-next-payment",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-06",
              "group_id" => "group-revisions",
              "amount_cents" => 1_000
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open-group-revisions",
                   "status" => "applied",
                   "group_id" => "group-revisions",
                   "deposit_due_cents" => 10_000,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-first-payment",
                   "status" => "applied",
                   "group_id" => "group-revisions",
                   "amount_cents" => 2_000,
                   "outstanding_deposit_cents" => 8_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-stale-invalid",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-revisions",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-next-payment",
                   "status" => "applied",
                   "group_id" => "group-revisions",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 7_000,
                   "revision" => 3
                 }
               ]
             }

      assert %{
               "data" => %{
                 "revision" => 3,
                 "deposit_paid_cents" => 3_000,
                 "outstanding_deposit_cents" => 7_000
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-revisions") |> json_response(200)
    end

    test "rejects invalid operations without rolling back earlier or later operations", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "bad-stay",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "bad-stay",
              "guest_id" => "guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-10",
              "rate_plan" => "flexible",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
            },
            %{
              "operation_id" => "bad-rooms",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "bad-rooms",
              "guest_id" => "guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rate_plan" => "flexible",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
                %{"room_id" => "room-a", "nightly_rate_cents" => 11_000}
              ]
            },
            %{
              "operation_id" => "bad-rate",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "bad-rate",
              "guest_id" => "guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rate_plan" => "mystery",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
            },
            flexible_open("valid-after-invalid")
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "bad-stay",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{
                   "operation_id" => "bad-rooms",
                   "status" => "rejected",
                   "code" => "invalid_rooms"
                 },
                 %{
                   "operation_id" => "bad-rate",
                   "status" => "rejected",
                   "code" => "invalid_rate_plan"
                 },
                 %{
                   "operation_id" => "op-open-valid-after-invalid",
                   "status" => "applied",
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/groups/bad-stay") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }

      assert get(build_conn(), ~p"/api/v1/groups/valid-after-invalid") |> json_response(200)
    end

    test "rejects duplicate group identifiers without replacing the original", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("group-duplicate"),
            %{
              "operation_id" => "op-duplicate",
              "type" => "open_group",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-duplicate",
              "guest_id" => "replacement-guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22",
              "rate_plan" => "advance_purchase",
              "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 99_999}]
            }
          ]
        })

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-duplicate",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "guest_id" => "guest-group-duplicate",
                 "arrival_on" => "2026-12-10",
                 "rate_plan" => "flexible",
                 "deposit_due_cents" => 10_000,
                 "revision" => 1
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-duplicate") |> json_response(200)
    end

    test "rejects group operations for missing groups, inactive groups, and bad amounts", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "missing-with-revision",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-03",
              "group_id" => "missing",
              "amount_cents" => 100,
              "expected_revision" => 99
            },
            flexible_open("group-errors"),
            %{
              "operation_id" => "bad-amount",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-errors",
              "amount_cents" => 0
            },
            %{
              "operation_id" => "too-much",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-errors",
              "amount_cents" => 10_001
            },
            %{
              "operation_id" => "cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-12-01",
              "group_id" => "group-errors"
            },
            %{
              "operation_id" => "pay-cancelled",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-12-02",
              "group_id" => "group-errors",
              "amount_cents" => 100
            }
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "missing-with-revision",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 },
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "bad-amount",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "too-much",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{"operation_id" => "cancel", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "pay-cancelled",
                   "status" => "rejected",
                   "code" => "group_not_active"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unknown and structurally invalid operations", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "unknown",
              "type" => "something_else",
              "occurred_on" => "2026-10-03"
            },
            %{
              "operation_id" => "missing-group",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-03"
            },
            "not-an-object"
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "missing-group",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
               ]
             }
    end

    test "replays applied operations exactly without reapplying current domain state", %{
      conn: conn
    } do
      payment =
        cash_payment("idempotent-group", 1_000, %{
          "operation_id" => "idem-payment",
          "expected_revision" => 1
        })

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("idempotent-group"),
            payment,
            cancel("idempotent-group", %{
              "operation_id" => "idem-cancel",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open-idempotent-group", "revision" => 1},
                 %{
                   "operation_id" => "idem-payment",
                   "status" => "applied",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 9_000,
                   "revision" => 2
                 },
                 %{"operation_id" => "idem-cancel", "revision" => 3}
               ]
             } = json_response(conn, 200)

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [payment]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "idem-payment",
                   "status" => "applied",
                   "group_id" => "idempotent-group",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 9_000,
                   "revision" => 2
                 }
               ]
             }

      assert get(build_conn(), ~p"/api/v1/operations/idem-payment") |> json_response(200) ==
               %{
                 "data" => %{
                   "operation_id" => "idem-payment",
                   "status" => "applied",
                   "group_id" => "idempotent-group",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 9_000,
                   "revision" => 2
                 }
               }

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "cash_paid_cents" => 1_000,
                 "revision" => 3
               }
             } = get(build_conn(), ~p"/api/v1/groups/idempotent-group") |> json_response(200)
    end

    test "remembers rejected results even when later state would make them valid", %{
      conn: conn
    } do
      early_payment = %{
        "operation_id" => "future-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "future-idempotent",
        "amount_cents" => 500
      }

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            early_payment,
            flexible_open("future-idempotent")
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "future-payment",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 },
                 %{"operation_id" => "op-open-future-idempotent", "revision" => 1}
               ]
             } = json_response(conn, 200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [early_payment]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "future-payment",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 10_000,
                 "revision" => 1
               }
             } = get(build_conn(), ~p"/api/v1/groups/future-idempotent") |> json_response(200)
    end

    test "rejects reused operation identifiers with different payloads", %{conn: conn} do
      original =
        flexible_open("payload-conflict", %{
          "operation_id" => "conflicting-operation",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 20_000}
          ]
        })

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [original]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "conflicting-operation",
                   "status" => "applied",
                   "deposit_due_cents" => 12_000,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      reversed_rooms =
        %{original | "rooms" => Enum.reverse(original["rooms"])}

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [reversed_rooms]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "conflicting-operation",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [original]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "conflicting-operation",
                   "status" => "applied",
                   "deposit_due_cents" => 12_000,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "replays stale revision details and conflicts corrected retries", %{conn: conn} do
      stale_payment =
        cash_payment("stale-idempotent", 100, %{
          "operation_id" => "idem-stale",
          "expected_revision" => 0
        })

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("stale-idempotent"),
            stale_payment,
            cash_payment("stale-idempotent", 500, %{"operation_id" => "advance-stale"})
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{
                   "operation_id" => "idem-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{"operation_id" => "advance-stale", "revision" => 2}
               ]
             } = json_response(conn, 200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [stale_payment]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "idem-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "stale-idempotent",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 }
               ]
             }

      assert get(build_conn(), ~p"/api/v1/operations/idem-stale") |> json_response(200) ==
               %{
                 "data" => %{
                   "operation_id" => "idem-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "stale-idempotent",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 }
               }

      corrected_retry = %{stale_payment | "expected_revision" => 2}

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [corrected_retry]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "idem-stale",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }
    end

    test "rejects invalid batch bodies", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns group_not_found for missing groups", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/groups/missing")

      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns operation_not_found for missing operations", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/operations/missing-operation")

      assert json_response(conn, 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp flexible_open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-#{group_id}",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 25_000}
        ]
      },
      overrides
    )
  end

  defp cash_payment(group_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay-#{group_id}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp apply_credit(group_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp cancel(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id
      },
      overrides
    )
  end
end
