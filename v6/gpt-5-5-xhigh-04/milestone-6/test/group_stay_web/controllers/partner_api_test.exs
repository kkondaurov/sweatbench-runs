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
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "status" => "active",
                     "lodging_total_cents" => 45_000,
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "status" => "active",
                     "lodging_total_cents" => 52_500,
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 5_506,
                 "credit_shortfall_cents" => 0
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
                   "cash_reduced_cents" => 0,
                   "cash_charged_back_cents" => 0,
                   "credit_liability_cents" => 0,
                   "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 2_200,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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

    test "allocates funding by room order and settles selected rooms", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("room-accounting", %{
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 5_000},
                %{"room_id" => "room-b", "nightly_rate_cents" => 10_000},
                %{"room_id" => "room-c", "nightly_rate_cents" => 15_000}
              ]
            }),
            cash_payment("room-accounting", 4_500, %{
              "operation_id" => "pay-room-accounting",
              "expected_revision" => 1
            }),
            cancel_rooms("room-accounting", ["room-c", "room-a"], %{
              "operation_id" => "cancel-selected-rooms",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"deposit_due_cents" => 6_000, "revision" => 1},
                 %{"outstanding_deposit_cents" => 1_500, "revision" => 2},
                 %{
                   "operation_id" => "cancel-selected-rooms",
                   "status" => "applied",
                   "group_id" => "room-accounting",
                   "cancelled_room_ids" => ["room-a", "room-c"],
                   "refunded_cents" => 2_500,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 10_000,
                 "deposit_due_cents" => 2_000,
                 "deposit_paid_cents" => 2_000,
                 "cash_paid_cents" => 2_000,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 2_000},
                   %{"room_id" => "room-c", "status" => "cancelled", "cash_paid_cents" => 0}
                 ]
               }
             } = get(build_conn(), ~p"/api/v1/groups/room-accounting") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/pay-room-accounting") |> json_response(200) ==
               %{
                 "data" => %{
                   "payment_operation_id" => "pay-room-accounting",
                   "original_group_id" => "room-accounting",
                   "recorded_cents" => 4_500,
                   "held_cents" => 2_000,
                   "refunded_cents" => 2_500,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 }
               }

      assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 2_000,
                 "cash_refunded_cents" => 2_500,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "reduces held cash in reverse fill order and keeps reduction idempotent", %{conn: conn} do
      reduction =
        reduce_payment("pay-reduction", 1_500, %{
          "operation_id" => "reduce-reduction",
          "expected_revision" => 2
        })

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("reduction", %{
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
                %{"room_id" => "room-b", "nightly_rate_cents" => 15_000}
              ]
            }),
            cash_payment("reduction", 4_000, %{
              "operation_id" => "pay-reduction",
              "expected_revision" => 1
            }),
            reduction
          ]
        })

      assert %{
               "results" => [
                 %{"deposit_due_cents" => 5_000, "revision" => 1},
                 %{"outstanding_deposit_cents" => 1_000, "revision" => 2},
                 %{
                   "operation_id" => "reduce-reduction",
                   "status" => "applied",
                   "payment_operation_id" => "pay-reduction",
                   "group_id" => "reduction",
                   "amount_cents" => 1_500,
                   "outstanding_deposit_cents" => 2_500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_paid_cents" => 2_500,
                 "outstanding_deposit_cents" => 2_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 500}
                 ]
               }
             } = get(build_conn(), ~p"/api/v1/groups/reduction") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/pay-reduction") |> json_response(200) ==
               %{
                 "data" => %{
                   "payment_operation_id" => "pay-reduction",
                   "original_group_id" => "reduction",
                   "recorded_cents" => 4_000,
                   "held_cents" => 2_500,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 1_500,
                   "charged_back_cents" => 0
                 }
               }

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [reduction]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "reduce-reduction",
                   "status" => "applied",
                   "amount_cents" => 1_500,
                   "outstanding_deposit_cents" => 2_500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conflict = %{reduction | "amount_cents" => 500}
      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [conflict]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "reduce-reduction",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }
    end

    test "chargebacks reclassify converted payments and report credit shortfall", %{conn: conn} do
      guest_id = "guest-chargeback"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("chargeback-source", %{
              "guest_id" => guest_id,
              "departure_on" => "2026-12-11",
              "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 10_000}]
            }),
            cash_payment("chargeback-source", 1_000, %{
              "operation_id" => "pay-chargeback-a",
              "expected_revision" => 1
            }),
            cash_payment("chargeback-source", 1_000, %{
              "operation_id" => "pay-chargeback-b",
              "expected_revision" => 2
            }),
            cancel("chargeback-source", %{
              "operation_id" => "cancel-chargeback-source",
              "occurred_on" => "2026-10-05",
              "refund_method" => "hotel_credit",
              "expected_revision" => 3
            }),
            flexible_open("chargeback-target", %{
              "guest_id" => guest_id
            }),
            apply_credit("chargeback-target", 1_500, %{
              "operation_id" => "apply-chargeback-credit",
              "expected_revision" => 1
            }),
            chargeback_payment("pay-chargeback-a", %{
              "operation_id" => "chargeback-a",
              "expected_revision" => 4
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"revision" => 3},
                 %{"credit_issued_cents" => 2_200, "revision" => 4},
                 %{"group_id" => "chargeback-target", "revision" => 1},
                 %{"outstanding_deposit_cents" => 8_500, "revision" => 2},
                 %{
                   "operation_id" => "chargeback-a",
                   "status" => "applied",
                   "payment_operation_id" => "pay-chargeback-a",
                   "group_id" => "chargeback-source",
                   "charged_back_cents" => 1_000,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 5
                 }
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"revision" => 5}} =
               get(build_conn(), ~p"/api/v1/groups/chargeback-source") |> json_response(200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "credit_paid_cents" => 1_500,
                 "outstanding_deposit_cents" => 8_500
               }
             } = get(build_conn(), ~p"/api/v1/groups/chargeback-target") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/ledger?on=2026-10-05") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 1_000,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 1_000,
                 "credit_liability_cents" => 1_500,
                 "credit_shortfall_cents" => 400
               }
             }

      assert get(build_conn(), ~p"/api/v1/payments/pay-chargeback-a") |> json_response(200) ==
               %{
                 "data" => %{
                   "payment_operation_id" => "pay-chargeback-a",
                   "original_group_id" => "chargeback-source",
                   "recorded_cents" => 1_000,
                   "held_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 1_000
                 }
               }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            cancel("chargeback-target", %{
              "operation_id" => "cancel-chargeback-target",
              "occurred_on" => "2026-10-06",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-chargeback-target",
                   "status" => "applied",
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit?on=2026-10-06")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => guest_id,
                 "available_cents" => 1_100,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-chargeback-source",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2027-10-06"
                   }
                 ]
               }
             }
    end

    test "transfers held cash and credit between active groups and replays idempotently", %{
      conn: conn
    } do
      guest_id = "guest-transfer"

      transfer =
        transfer_deposit("transfer-source", "transfer-destination", 1_600, %{
          "operation_id" => "transfer-mixed-funding",
          "expected_revision" => 3,
          "destination_expected_revision" => 1
        })

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("transfer-credit-source", %{
              "guest_id" => guest_id
            }),
            cash_payment("transfer-credit-source", 1_000, %{
              "operation_id" => "pay-transfer-credit-source",
              "expected_revision" => 1
            }),
            cancel("transfer-credit-source", %{
              "operation_id" => "cancel-transfer-credit-source",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            }),
            flexible_open("transfer-source", %{
              "guest_id" => guest_id,
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "source-a", "nightly_rate_cents" => 10_000},
                %{"room_id" => "source-b", "nightly_rate_cents" => 15_000}
              ]
            }),
            cash_payment("transfer-source", 2_500, %{
              "operation_id" => "pay-transfer-cash",
              "expected_revision" => 1
            }),
            apply_credit("transfer-source", 1_100, %{
              "operation_id" => "apply-transfer-credit",
              "occurred_on" => "2026-10-06",
              "expected_revision" => 2
            }),
            flexible_open("transfer-destination", %{
              "guest_id" => guest_id,
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "dest-a", "nightly_rate_cents" => 5_000},
                %{"room_id" => "dest-b", "nightly_rate_cents" => 5_000}
              ]
            }),
            transfer
          ]
        })

      assert %{
               "results" => [
                 %{"group_id" => "transfer-credit-source", "revision" => 1},
                 %{"revision" => 2},
                 %{"credit_issued_cents" => 1_100, "revision" => 3},
                 %{"group_id" => "transfer-source", "revision" => 1},
                 %{"outstanding_deposit_cents" => 2_500, "revision" => 2},
                 %{"outstanding_deposit_cents" => 1_400, "revision" => 3},
                 %{"group_id" => "transfer-destination", "revision" => 1},
                 %{
                   "operation_id" => "transfer-mixed-funding",
                   "status" => "applied",
                   "source_group_id" => "transfer-source",
                   "destination_group_id" => "transfer-destination",
                   "amount_cents" => 1_600,
                   "source_outstanding_deposit_cents" => 3_000,
                   "destination_outstanding_deposit_cents" => 400,
                   "source_revision" => 4,
                   "destination_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 4,
                 "cash_paid_cents" => 2_000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 3_000,
                 "rooms" => [
                   %{"room_id" => "source-a", "cash_paid_cents" => 2_000},
                   %{"room_id" => "source-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = get(build_conn(), ~p"/api/v1/groups/transfer-source") |> json_response(200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "cash_paid_cents" => 500,
                 "credit_paid_cents" => 1_100,
                 "outstanding_deposit_cents" => 400,
                 "rooms" => [
                   %{"room_id" => "dest-a", "cash_paid_cents" => 0, "credit_paid_cents" => 1_000},
                   %{"room_id" => "dest-b", "cash_paid_cents" => 500, "credit_paid_cents" => 100}
                 ]
               }
             } =
               get(build_conn(), ~p"/api/v1/groups/transfer-destination") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-cash") |> json_response(200) ==
               %{
                 "data" => %{
                   "payment_operation_id" => "pay-transfer-cash",
                   "original_group_id" => "transfer-source",
                   "recorded_cents" => 2_500,
                   "held_cents" => 2_500,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0,
                   "held_by_group" => [
                     %{"group_id" => "transfer-destination", "amount_cents" => 500},
                     %{"group_id" => "transfer-source", "amount_cents" => 2_000}
                   ]
                 }
               }

      assert get(build_conn(), ~p"/api/v1/ledger?on=2026-10-06") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 2_500,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 1_000,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 1_100,
                 "credit_shortfall_cents" => 0
               }
             }

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [transfer]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "transfer-mixed-funding",
                   "status" => "applied",
                   "source_group_id" => "transfer-source",
                   "destination_group_id" => "transfer-destination",
                   "amount_cents" => 1_600,
                   "source_outstanding_deposit_cents" => 3_000,
                   "destination_outstanding_deposit_cents" => 400,
                   "source_revision" => 4,
                   "destination_revision" => 2
                 }
               ]
             }

      assert %{"data" => %{"revision" => 4}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-source") |> json_response(200)

      assert %{"data" => %{"revision" => 2}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-destination") |> json_response(200)
    end

    test "settles transferred funding under the destination group", %{conn: conn} do
      guest_id = "guest-transfer-settlement"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("transfer-settlement-credit-source", %{
              "guest_id" => guest_id
            }),
            cash_payment("transfer-settlement-credit-source", 1_000, %{
              "operation_id" => "pay-transfer-settlement-credit-source"
            }),
            cancel("transfer-settlement-credit-source", %{
              "operation_id" => "cancel-transfer-settlement-credit-source",
              "refund_method" => "hotel_credit"
            }),
            flexible_open("transfer-settlement-source", %{
              "guest_id" => guest_id
            }),
            cash_payment("transfer-settlement-source", 1_000, %{
              "operation_id" => "pay-transfer-settlement-cash",
              "expected_revision" => 1
            }),
            apply_credit("transfer-settlement-source", 1_000, %{
              "operation_id" => "apply-transfer-settlement-credit",
              "occurred_on" => "2026-10-06",
              "expected_revision" => 2
            }),
            flexible_open("transfer-settlement-destination", %{
              "guest_id" => guest_id
            }),
            transfer_deposit(
              "transfer-settlement-source",
              "transfer-settlement-destination",
              1_500,
              %{
                "operation_id" => "transfer-settlement",
                "expected_revision" => 3,
                "destination_expected_revision" => 1
              }
            ),
            cancel("transfer-settlement-destination", %{
              "operation_id" => "cancel-transfer-settlement-destination",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"credit_issued_cents" => 1_100, "revision" => 3},
                 %{"group_id" => "transfer-settlement-source", "revision" => 1},
                 %{"revision" => 2},
                 %{"revision" => 3},
                 %{"group_id" => "transfer-settlement-destination", "revision" => 1},
                 %{
                   "source_outstanding_deposit_cents" => 9_500,
                   "destination_outstanding_deposit_cents" => 8_500,
                   "source_revision" => 4,
                   "destination_revision" => 2
                 },
                 %{
                   "operation_id" => "cancel-transfer-settlement-destination",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 550,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit?on=2026-10-06")
             |> json_response(200) == %{
               "data" => %{
                 "guest_id" => guest_id,
                 "available_cents" => 1_650,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-transfer-settlement-credit-source",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2027-10-06"
                   },
                   %{
                     "source_operation_id" => "cancel-transfer-settlement-destination",
                     "remaining_cents" => 550,
                     "expires_on" => "2027-10-06"
                   }
                 ]
               }
             }

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-settlement-cash")
             |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-transfer-settlement-cash",
                 "original_group_id" => "transfer-settlement-source",
                 "recorded_cents" => 1_000,
                 "held_cents" => 500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 500,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "transfer-settlement-source", "amount_cents" => 500}
                 ]
               }
             }
    end

    test "corrections follow transferred cash and advance affected group revisions", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("transfer-correction-source", %{
              "guest_id" => "guest-transfer-correction"
            }),
            cash_payment("transfer-correction-source", 1_000, %{
              "operation_id" => "pay-transfer-correction",
              "expected_revision" => 1
            }),
            flexible_open("transfer-correction-destination", %{
              "guest_id" => "guest-transfer-correction"
            }),
            transfer_deposit(
              "transfer-correction-source",
              "transfer-correction-destination",
              600,
              %{
                "operation_id" => "transfer-correction",
                "expected_revision" => 2,
                "destination_expected_revision" => 1
              }
            ),
            reduce_payment("pay-transfer-correction", 500, %{
              "operation_id" => "reduce-transferred-cash",
              "expected_revision" => 3
            }),
            chargeback_payment("pay-transfer-correction", %{
              "operation_id" => "chargeback-transferred-cash",
              "expected_revision" => 4
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"group_id" => "transfer-correction-destination", "revision" => 1},
                 %{"source_revision" => 3, "destination_revision" => 2},
                 %{
                   "operation_id" => "reduce-transferred-cash",
                   "status" => "applied",
                   "payment_operation_id" => "pay-transfer-correction",
                   "group_id" => "transfer-correction-source",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 9_600,
                   "revision" => 4
                 },
                 %{
                   "operation_id" => "chargeback-transferred-cash",
                   "status" => "applied",
                   "payment_operation_id" => "pay-transfer-correction",
                   "group_id" => "transfer-correction-source",
                   "charged_back_cents" => 500,
                   "outstanding_deposit_cents" => 10_000,
                   "revision" => 5
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 5,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 10_000
               }
             } =
               get(build_conn(), ~p"/api/v1/groups/transfer-correction-source")
               |> json_response(200)

      assert %{
               "data" => %{
                 "revision" => 4,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 10_000
               }
             } =
               get(build_conn(), ~p"/api/v1/groups/transfer-correction-destination")
               |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-correction")
             |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-transfer-correction",
                 "original_group_id" => "transfer-correction-source",
                 "recorded_cents" => 1_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 500,
                 "charged_back_cents" => 500,
                 "held_by_group" => []
               }
             }

      assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 500,
                 "cash_charged_back_cents" => 500,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "starts finance reporting with opening state and same-batch movements", %{conn: conn} do
      start = finance_start("2026-10-10", %{"operation_id" => "start-finance-opening"})

      pay_after_start =
        cash_payment("finance-opening", 500, %{
          "operation_id" => "pay-after-finance-start",
          "occurred_on" => "2026-10-05",
          "expected_revision" => 2
        })

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("finance-opening"),
            cash_payment("finance-opening", 1_000, %{
              "operation_id" => "pay-before-finance-start",
              "occurred_on" => "2026-10-12",
              "expected_revision" => 1
            }),
            start,
            pay_after_start
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open-finance-opening",
                   "status" => "applied",
                   "group_id" => "finance-opening",
                   "deposit_due_cents" => 10_000,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "pay-before-finance-start",
                   "status" => "applied",
                   "group_id" => "finance-opening",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 9_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "start-finance-opening",
                   "status" => "applied",
                   "starts_on" => "2026-10-10"
                 },
                 %{
                   "operation_id" => "pay-after-finance-start",
                   "status" => "applied",
                   "group_id" => "finance-opening",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 8_500,
                   "revision" => 3
                 }
               ]
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-09")
             |> json_response(404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      report =
        get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-10")
        |> json_response(200)

      assert report == %{
               "data" => %{
                 "date" => "2026-10-10",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 1_000,
                     "movements" => cash_movements(%{"received_cents" => 500}),
                     "closing_held_cents" => 1_500
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 0,
                   "movements" => credit_movements(),
                   "closing_liability_cents" => 0
                 }
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-10")
             |> json_response(200) == report

      assert post(build_conn(), ~p"/api/v1/partner-batches", %{
               "operations" => [pay_after_start]
             })
             |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "pay-after-finance-start",
                   "status" => "applied",
                   "group_id" => "finance-opening",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 8_500,
                   "revision" => 3
                 }
               ]
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-10")
             |> json_response(200) == report
    end

    test "rejects invalid and repeated finance reporting starts durably", %{conn: conn} do
      start = finance_start("2026-10-01", %{"operation_id" => "start-finance-once"})

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            finance_start("bad-date", %{"operation_id" => "start-finance-bad-date"}),
            start,
            finance_start("2026-10-02", %{"operation_id" => "start-finance-again"})
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "start-finance-bad-date",
                   "status" => "rejected",
                   "code" => "invalid_reporting_date"
                 },
                 %{
                   "operation_id" => "start-finance-once",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 },
                 %{
                   "operation_id" => "start-finance-again",
                   "status" => "rejected",
                   "code" => "reporting_already_started"
                 }
               ]
             }

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [start]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "start-finance-once",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 }
               ]
             }
    end

    test "reports cash transfer and correction movements by property", %{conn: conn} do
      guest_id = "guest-finance-cash"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            finance_start("2026-10-01", %{"operation_id" => "start-finance-cash"}),
            flexible_open("finance-cash-source", %{
              "guest_id" => guest_id,
              "property_id" => "ams-canal"
            }),
            flexible_open("finance-cash-destination", %{
              "guest_id" => guest_id,
              "property_id" => "rot-harbor"
            }),
            cash_payment("finance-cash-source", 2_000, %{
              "operation_id" => "pay-finance-cash",
              "occurred_on" => "2026-10-02",
              "expected_revision" => 1
            }),
            transfer_deposit("finance-cash-source", "finance-cash-destination", 700, %{
              "operation_id" => "transfer-finance-cash",
              "occurred_on" => "2026-10-03",
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }),
            reduce_payment("pay-finance-cash", 300, %{
              "operation_id" => "reduce-finance-cash",
              "occurred_on" => "2026-10-03",
              "expected_revision" => 3
            })
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "start-finance-cash", "status" => "applied"},
                 %{"group_id" => "finance-cash-source", "revision" => 1},
                 %{"group_id" => "finance-cash-destination", "revision" => 1},
                 %{"operation_id" => "pay-finance-cash", "revision" => 2},
                 %{"operation_id" => "transfer-finance-cash", "source_revision" => 3},
                 %{"operation_id" => "reduce-finance-cash", "revision" => 4}
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2026-10-03",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 2_000,
                     "movements" => cash_movements(%{"transferred_out_cents" => 700}),
                     "closing_held_cents" => 1_300
                   },
                   %{
                     "property_id" => "rot-harbor",
                     "opening_held_cents" => 0,
                     "movements" =>
                       cash_movements(%{
                         "transferred_in_cents" => 700,
                         "reduced_cents" => 300
                       }),
                     "closing_held_cents" => 400
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 0,
                   "movements" => credit_movements(),
                   "closing_liability_cents" => 0
                 }
               }
             }
    end

    test "reports converted cash and chargeback reclassifications", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            finance_start("2026-10-01", %{"operation_id" => "start-finance-chargeback"}),
            flexible_open("finance-chargeback-source", %{
              "occurred_on" => "2026-09-30",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22"
            }),
            cash_payment("finance-chargeback-source", 1_000, %{
              "operation_id" => "pay-finance-chargeback",
              "occurred_on" => "2026-10-02",
              "expected_revision" => 1
            }),
            cancel("finance-chargeback-source", %{
              "operation_id" => "cancel-finance-chargeback-source",
              "occurred_on" => "2026-10-03",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            }),
            chargeback_payment("pay-finance-chargeback", %{
              "operation_id" => "chargeback-finance-converted",
              "occurred_on" => "2026-10-04",
              "expected_revision" => 3
            })
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "start-finance-chargeback", "status" => "applied"},
                 %{"group_id" => "finance-chargeback-source", "revision" => 1},
                 %{"operation_id" => "pay-finance-chargeback", "revision" => 2},
                 %{
                   "operation_id" => "cancel-finance-chargeback-source",
                   "credit_issued_cents" => 1_100,
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "chargeback-finance-converted",
                   "charged_back_cents" => 1_000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2026-10-03",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 1_000,
                     "movements" => cash_movements(%{"converted_to_credit_cents" => 1_000}),
                     "closing_held_cents" => 0
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 0,
                   "movements" => credit_movements(%{"issued_cents" => 1_100}),
                   "closing_liability_cents" => 1_100
                 }
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-04")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2026-10-04",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 0,
                     "movements" =>
                       cash_movements(%{
                         "converted_to_credit_cents" => -1_000,
                         "charged_back_cents" => 1_000
                       }),
                     "closing_held_cents" => 0
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 1_100,
                   "movements" => credit_movements(%{"revoked_cents" => 1_100}),
                   "closing_liability_cents" => 0
                 }
               }
             }
    end

    test "reports credit consumption and unused credit expiry without operations", %{conn: conn} do
      guest_id = "guest-finance-expiry"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            finance_start("2026-10-01", %{"operation_id" => "start-finance-expiry"}),
            flexible_open("finance-expiry-source", %{
              "guest_id" => guest_id,
              "occurred_on" => "2026-09-30",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22"
            }),
            cash_payment("finance-expiry-source", 1_000, %{
              "operation_id" => "pay-finance-expiry-source",
              "occurred_on" => "2026-10-01",
              "expected_revision" => 1
            }),
            cancel("finance-expiry-source", %{
              "operation_id" => "cancel-finance-expiry-source",
              "occurred_on" => "2026-10-02",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            }),
            advance_open("finance-consume-target", %{
              "guest_id" => guest_id,
              "occurred_on" => "2026-10-02"
            }),
            apply_credit("finance-consume-target", 600, %{
              "operation_id" => "apply-finance-consume-credit",
              "occurred_on" => "2026-10-03",
              "expected_revision" => 1
            }),
            cancel("finance-consume-target", %{
              "operation_id" => "cancel-finance-consume-target",
              "occurred_on" => "2026-10-04",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "start-finance-expiry", "status" => "applied"},
                 %{"group_id" => "finance-expiry-source", "revision" => 1},
                 %{"operation_id" => "pay-finance-expiry-source", "revision" => 2},
                 %{
                   "operation_id" => "cancel-finance-expiry-source",
                   "credit_issued_cents" => 1_100,
                   "revision" => 3
                 },
                 %{"group_id" => "finance-consume-target", "revision" => 1},
                 %{"operation_id" => "apply-finance-consume-credit", "revision" => 2},
                 %{
                   "operation_id" => "cancel-finance-consume-target",
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-04")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2026-10-04",
                 "status" => "open",
                 "cash" => [],
                 "credit" => %{
                   "opening_liability_cents" => 1_100,
                   "movements" => credit_movements(%{"consumed_cents" => 600}),
                   "closing_liability_cents" => 500
                 }
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-10-03")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-10-03",
                 "status" => "open",
                 "cash" => [],
                 "credit" => %{
                   "opening_liability_cents" => 500,
                   "movements" => credit_movements(%{"expired_cents" => 500}),
                   "closing_liability_cents" => 0
                 }
               }
             }
    end

    test "reports credit shortfall absorption on refundable restoration", %{conn: conn} do
      guest_id = "guest-finance-absorption"

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            finance_start("2026-10-01", %{"operation_id" => "start-finance-absorption"}),
            flexible_open("finance-absorption-source", %{
              "guest_id" => guest_id,
              "occurred_on" => "2026-09-30",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22"
            }),
            cash_payment("finance-absorption-source", 1_000, %{
              "operation_id" => "pay-finance-absorption-source",
              "occurred_on" => "2026-10-01",
              "expected_revision" => 1
            }),
            cancel("finance-absorption-source", %{
              "operation_id" => "cancel-finance-absorption-source",
              "occurred_on" => "2026-10-02",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            }),
            flexible_open("finance-absorption-target", %{
              "guest_id" => guest_id,
              "occurred_on" => "2026-10-02",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22"
            }),
            apply_credit("finance-absorption-target", 700, %{
              "operation_id" => "apply-finance-absorption-credit",
              "occurred_on" => "2026-10-03",
              "expected_revision" => 1
            }),
            chargeback_payment("pay-finance-absorption-source", %{
              "operation_id" => "chargeback-finance-absorption",
              "occurred_on" => "2026-10-04",
              "expected_revision" => 3
            }),
            cancel("finance-absorption-target", %{
              "operation_id" => "cancel-finance-absorption-target",
              "occurred_on" => "2026-10-05",
              "expected_revision" => 2
            })
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "start-finance-absorption", "status" => "applied"},
                 %{"group_id" => "finance-absorption-source", "revision" => 1},
                 %{"operation_id" => "pay-finance-absorption-source", "revision" => 2},
                 %{"operation_id" => "cancel-finance-absorption-source", "revision" => 3},
                 %{"group_id" => "finance-absorption-target", "revision" => 1},
                 %{"operation_id" => "apply-finance-absorption-credit", "revision" => 2},
                 %{
                   "operation_id" => "chargeback-finance-absorption",
                   "charged_back_cents" => 1_000,
                   "revision" => 4
                 },
                 %{
                   "operation_id" => "cancel-finance-absorption-target",
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-04")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2026-10-04",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 0,
                     "movements" =>
                       cash_movements(%{
                         "converted_to_credit_cents" => -1_000,
                         "charged_back_cents" => 1_000
                       }),
                     "closing_held_cents" => 0
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 1_100,
                   "movements" => credit_movements(%{"revoked_cents" => 400}),
                   "closing_liability_cents" => 700
                 }
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-05")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2026-10-05",
                 "status" => "open",
                 "cash" => [],
                 "credit" => %{
                   "opening_liability_cents" => 700,
                   "movements" => credit_movements(%{"absorbed_cents" => 700}),
                   "closing_liability_cents" => 0
                 }
               }
             }
    end

    test "rejects invalid transfers without advancing revisions", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            transfer_deposit("missing-source", "missing-destination", 100, %{
              "operation_id" => "transfer-missing-source"
            }),
            flexible_open("transfer-error-source", %{
              "guest_id" => "guest-transfer-errors"
            }),
            flexible_open("transfer-error-destination", %{
              "guest_id" => "guest-transfer-errors"
            }),
            flexible_open("transfer-error-other-guest", %{
              "guest_id" => "guest-transfer-errors-other"
            }),
            flexible_open("transfer-error-inactive", %{
              "guest_id" => "guest-transfer-errors"
            }),
            cancel("transfer-error-inactive", %{
              "operation_id" => "cancel-transfer-error-inactive",
              "expected_revision" => 1
            }),
            cash_payment("transfer-error-source", 500, %{
              "operation_id" => "pay-transfer-errors",
              "expected_revision" => 1
            }),
            transfer_deposit("transfer-error-source", "missing-destination", 100, %{
              "operation_id" => "transfer-missing-destination"
            }),
            transfer_deposit("transfer-error-source", "transfer-error-destination", 100, %{
              "operation_id" => "transfer-stale-source",
              "expected_revision" => 1,
              "destination_expected_revision" => 1
            }),
            transfer_deposit("transfer-error-source", "transfer-error-destination", 100, %{
              "operation_id" => "transfer-stale-destination",
              "expected_revision" => 2,
              "destination_expected_revision" => 0
            }),
            transfer_deposit("transfer-error-source", "transfer-error-source", 100, %{
              "operation_id" => "transfer-same-group",
              "expected_revision" => 2,
              "destination_expected_revision" => 2
            }),
            transfer_deposit("transfer-error-source", "transfer-error-other-guest", 100, %{
              "operation_id" => "transfer-different-guest",
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }),
            transfer_deposit("transfer-error-source", "transfer-error-inactive", 100, %{
              "operation_id" => "transfer-inactive-destination",
              "expected_revision" => 2,
              "destination_expected_revision" => 2
            }),
            transfer_deposit("transfer-error-source", "transfer-error-destination", 0, %{
              "operation_id" => "transfer-invalid-amount"
            }),
            transfer_deposit("transfer-error-source", "transfer-error-destination", 501, %{
              "operation_id" => "transfer-too-much-held"
            }),
            flexible_open("transfer-error-small-destination", %{
              "guest_id" => "guest-transfer-errors",
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "small-room", "nightly_rate_cents" => 500}
              ]
            }),
            transfer_deposit("transfer-error-source", "transfer-error-small-destination", 101, %{
              "operation_id" => "transfer-too-much-outstanding",
              "destination_expected_revision" => 1
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "transfer-missing-source",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "missing-source"
                 },
                 %{"group_id" => "transfer-error-source", "revision" => 1},
                 %{"group_id" => "transfer-error-destination", "revision" => 1},
                 %{"group_id" => "transfer-error-other-guest", "revision" => 1},
                 %{"group_id" => "transfer-error-inactive", "revision" => 1},
                 %{"group_id" => "transfer-error-inactive", "revision" => 2},
                 %{"group_id" => "transfer-error-source", "revision" => 2},
                 %{
                   "operation_id" => "transfer-missing-destination",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "missing-destination"
                 },
                 %{
                   "operation_id" => "transfer-stale-source",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "transfer-error-source",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "transfer-stale-destination",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "transfer-error-destination",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{"operation_id" => "transfer-same-group", "code" => "invalid_transfer"},
                 %{"operation_id" => "transfer-different-guest", "code" => "invalid_transfer"},
                 %{
                   "operation_id" => "transfer-inactive-destination",
                   "code" => "group_not_active",
                   "group_id" => "transfer-error-inactive"
                 },
                 %{"operation_id" => "transfer-invalid-amount", "code" => "invalid_amount"},
                 %{
                   "operation_id" => "transfer-too-much-held",
                   "code" => "transfer_exceeds_held_funding"
                 },
                 %{"group_id" => "transfer-error-small-destination", "revision" => 1},
                 %{
                   "operation_id" => "transfer-too-much-outstanding",
                   "code" => "transfer_exceeds_outstanding"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "cash_paid_cents" => 500,
                 "outstanding_deposit_cents" => 9_500
               }
             } = get(build_conn(), ~p"/api/v1/groups/transfer-error-source") |> json_response(200)

      assert %{
               "data" => %{
                 "revision" => 1,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 10_000
               }
             } =
               get(build_conn(), ~p"/api/v1/groups/transfer-error-destination")
               |> json_response(200)
    end

    test "rejects invalid room cancellation and payment correction targets", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("correction-errors"),
            cash_payment("correction-errors", 1_000, %{
              "operation_id" => "pay-correction-errors",
              "expected_revision" => 1
            }),
            cancel_rooms("correction-errors", ["room-a", "room-a"], %{
              "operation_id" => "bad-room-cancel",
              "expected_revision" => 2
            }),
            reduce_payment("missing-payment", 100, %{"operation_id" => "missing-reduction"}),
            reduce_payment("op-open-correction-errors", 100, %{
              "operation_id" => "non-payment-reduction"
            }),
            reduce_payment("pay-correction-errors", 0, %{"operation_id" => "bad-reduction"}),
            reduce_payment("pay-correction-errors", 1_001, %{
              "operation_id" => "too-large-reduction"
            }),
            chargeback_payment("missing-payment", %{"operation_id" => "missing-chargeback"}),
            chargeback_payment("op-open-correction-errors", %{
              "operation_id" => "non-payment-chargeback"
            })
          ]
        })

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"operation_id" => "bad-room-cancel", "code" => "invalid_rooms"},
                 %{"operation_id" => "missing-reduction", "code" => "operation_not_found"},
                 %{"operation_id" => "non-payment-reduction", "code" => "payment_not_reducible"},
                 %{"operation_id" => "bad-reduction", "code" => "invalid_amount"},
                 %{
                   "operation_id" => "too-large-reduction",
                   "code" => "reduction_exceeds_held_cash"
                 },
                 %{"operation_id" => "missing-chargeback", "code" => "operation_not_found"},
                 %{
                   "operation_id" => "non-payment-chargeback",
                   "code" => "payment_not_chargeable"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "cash_paid_cents" => 1_000,
                 "outstanding_deposit_cents" => 9_000
               }
             } = get(build_conn(), ~p"/api/v1/groups/correction-errors") |> json_response(200)
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
                 "cash_paid_cents" => 0,
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

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns operation_not_found for missing payment operations", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/payments/missing-payment")

      assert json_response(conn, 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end

    test "returns payment_not_reconcilable for non-cash operations", %{conn: conn} do
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [flexible_open("not-a-payment")]
      })

      conn = get(build_conn(), ~p"/api/v1/payments/op-open-not-a-payment")

      assert json_response(conn, 422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "validates date and requires an available report", %{conn: conn} do
      assert get(conn, ~p"/api/v1/finance/daily-report") |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=not-a-date")
             |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-01")
             |> json_response(404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          finance_start("2026-10-10", %{"operation_id" => "start-finance-errors"})
        ]
      })

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-09")
             |> json_response(404) == %{
               "error" => %{"code" => "report_not_available"}
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

  defp advance_open(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-#{group_id}",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "advance_purchase",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 1_000}
        ]
      },
      overrides
    )
  end

  defp finance_start(starts_on, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-start-finance-#{starts_on}",
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
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

  defp cancel_rooms(group_id, room_ids, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms-#{group_id}",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  defp reduce_payment(payment_operation_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce-#{payment_operation_id}",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp chargeback_payment(payment_operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback-#{payment_operation_id}",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp transfer_deposit(source_group_id, destination_group_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-transfer-#{source_group_id}-#{destination_group_id}",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end
end
