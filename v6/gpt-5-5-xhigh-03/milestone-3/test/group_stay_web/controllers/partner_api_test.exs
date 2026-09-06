defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.PartnerOperation

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array" do
      response =
        build_conn()
        |> post(~p"/api/v1/partner-batches", %{})
        |> json_response(422)

      assert response == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "opens a flexible group and exposes the group read model" do
      response = submit_batch([open_group_operation()])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      assert read_group("group-81") == %{
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
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
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

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "rounds flexible deposits per room before summing the group deposit" do
      response =
        submit_batch([
          open_group_operation(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 3},
              %{"room_id" => "room-b", "nightly_rate_cents" => 3}
            ]
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 2,
                   "revision" => 1
                 }
               ]
             }

      assert read_group("group-81")["data"]["lodging_total_cents"] == 6
    end

    test "processes operations in order and continues after rejected operations" do
      response =
        submit_batch([
          open_group_operation(),
          cash_payment_operation(%{
            "operation_id" => "op-pay",
            "amount_cents" => 10_000,
            "expected_revision" => 1
          }),
          reschedule_operation(%{
            "operation_id" => "op-move",
            "expected_revision" => 2,
            "new_arrival_on" => "2026-12-17"
          }),
          cash_payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => -1,
            "expected_revision" => 2
          }),
          cash_payment_operation(%{
            "operation_id" => "op-pay-rest",
            "amount_cents" => 9_500,
            "expected_revision" => 3
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel",
            "occurred_on" => "2026-12-01",
            "expected_revision" => 4
          }),
          cash_payment_operation(%{
            "operation_id" => "op-after-cancel",
            "amount_cents" => 1
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-17",
                   "new_departure_on" => "2026-12-20",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-03",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 2,
                   "actual_revision" => 3
                 },
                 %{
                   "operation_id" => "op-pay-rest",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 9_500,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 4
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 19_500,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 5
                 },
                 %{
                   "operation_id" => "op-after-cancel",
                   "status" => "rejected",
                   "code" => "group_not_active"
                 }
               ]
             }

      assert read_group("group-81")["data"] == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 5,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-17",
               "departure_on" => "2026-12-20",
               "rate_plan" => "flexible",
               "status" => "cancelled",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-03",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 19_500,
               "cash_paid_cents" => 19_500,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19_500,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "rejects invalid open operations without blocking later operations" do
      response =
        submit_batch([
          open_group_operation(),
          open_group_operation(%{"operation_id" => "op-duplicate"}),
          open_group_operation(%{
            "operation_id" => "op-invalid-stay",
            "group_id" => "group-invalid-stay",
            "departure_on" => "2026-12-10"
          }),
          open_group_operation(%{
            "operation_id" => "op-invalid-rooms",
            "group_id" => "group-invalid-rooms",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
            ]
          }),
          open_group_operation(%{
            "operation_id" => "op-invalid-plan",
            "group_id" => "group-invalid-plan",
            "rate_plan" => "semi_flexible"
          }),
          Map.delete(
            open_group_operation(%{"group_id" => "group-missing-operation-id"}),
            "operation_id"
          ),
          %{"operation_id" => "op-unknown", "type" => "adjust_group"},
          %{
            "operation_id" => "op-missing-group",
            "type" => "record_cash_payment",
            "amount_cents" => 1
          },
          open_group_operation(%{"operation_id" => "op-later", "group_id" => "group-later"})
        ])

      assert Enum.map(response["results"], & &1["code"]) == [
               nil,
               "group_already_exists",
               "invalid_stay",
               "invalid_rooms",
               "invalid_rate_plan",
               "invalid_operation",
               "invalid_operation",
               "invalid_operation",
               nil
             ]

      assert read_group("group-81")["data"]["revision"] == 1
      assert read_group("group-later")["data"]["revision"] == 1

      assert read_missing_group("group-invalid-stay") == %{
               "error" => %{"code" => "group_not_found"}
             }

      assert read_missing_group("group-missing-operation-id") == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "validates payments and checks stale revisions before payment rules" do
      submit_batch([open_group_operation()])

      response =
        submit_batch([
          cash_payment_operation(%{
            "operation_id" => "op-missing",
            "group_id" => "missing-group",
            "amount_cents" => 1,
            "expected_revision" => 99
          }),
          cash_payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => -1,
            "expected_revision" => 0
          }),
          Map.delete(
            cash_payment_operation(%{"operation_id" => "op-missing-amount"}),
            "amount_cents"
          ),
          cash_payment_operation(%{"operation_id" => "op-invalid", "amount_cents" => 0}),
          cash_payment_operation(%{"operation_id" => "op-too-much", "amount_cents" => 19_501}),
          cash_payment_operation(%{"operation_id" => "op-valid", "amount_cents" => 19_500})
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-missing",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "missing-group"
                 },
                 %{
                   "operation_id" => "op-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{
                   "operation_id" => "op-missing-amount",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "op-invalid",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "op-too-much",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{
                   "operation_id" => "op-valid",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 19_500,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 2
                 }
               ]
             }

      assert read_group("group-81")["data"]["revision"] == 2
      assert read_group("group-81")["data"]["deposit_paid_cents"] == 19_500
      assert read_ledger()["data"]["cash_held_cents"] == 19_500
    end

    test "validates reschedules and checks stale revisions before date rules" do
      submit_batch([open_group_operation()])

      response =
        submit_batch([
          reschedule_operation(%{
            "operation_id" => "op-stale",
            "expected_revision" => 0,
            "new_arrival_on" => "2026-10-01"
          }),
          reschedule_operation(%{
            "operation_id" => "op-invalid-date",
            "new_arrival_on" => "2026-10-03"
          }),
          reschedule_operation(%{
            "operation_id" => "op-malformed-date",
            "new_arrival_on" => "not-a-date"
          }),
          reschedule_operation(%{
            "operation_id" => "op-valid",
            "new_arrival_on" => "2026-11-01",
            "expected_revision" => 1
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{
                   "operation_id" => "op-invalid-date",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{
                   "operation_id" => "op-malformed-date",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{
                   "operation_id" => "op-valid",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-11-01",
                   "new_departure_on" => "2026-11-04",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-10-18",
                   "revision" => 2
                 }
               ]
             }
    end

    test "settles late flexible and advance purchase cancellations as retained cash" do
      response =
        submit_batch([
          open_group_operation(%{"operation_id" => "op-open-flex", "group_id" => "group-flex"}),
          cash_payment_operation(%{
            "operation_id" => "op-pay-flex",
            "group_id" => "group-flex",
            "amount_cents" => 19_500
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-flex",
            "group_id" => "group-flex",
            "occurred_on" => "2026-12-01"
          }),
          open_group_operation(%{
            "operation_id" => "op-open-advance",
            "group_id" => "group-advance",
            "rate_plan" => "advance_purchase"
          }),
          cash_payment_operation(%{
            "operation_id" => "op-pay-advance",
            "group_id" => "group-advance",
            "amount_cents" => 97_500
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-advance",
            "group_id" => "group-advance",
            "occurred_on" => "2026-10-04"
          })
        ])

      assert Enum.at(response["results"], 2) == %{
               "operation_id" => "op-cancel-flex",
               "status" => "applied",
               "group_id" => "group-flex",
               "refunded_cents" => 0,
               "retained_cents" => 19_500,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert Enum.at(response["results"], 3) == %{
               "operation_id" => "op-open-advance",
               "status" => "applied",
               "group_id" => "group-advance",
               "deposit_due_cents" => 97_500,
               "revision" => 1
             }

      assert Enum.at(response["results"], 5) == %{
               "operation_id" => "op-cancel-advance",
               "status" => "applied",
               "group_id" => "group-advance",
               "refunded_cents" => 0,
               "retained_cents" => 97_500,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 117_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "assigns fixed policy versions and recomputes refundable dates after rescheduling" do
      response =
        submit_batch([
          open_group_operation(%{
            "operation_id" => "op-open-old",
            "group_id" => "group-old",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          open_group_operation(%{
            "operation_id" => "op-open-new",
            "group_id" => "group-new",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          open_group_operation(%{
            "operation_id" => "op-open-advance",
            "group_id" => "group-advance",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18",
            "rate_plan" => "advance_purchase"
          }),
          reschedule_operation(%{
            "operation_id" => "op-move-new",
            "group_id" => "group-new",
            "occurred_on" => "2027-01-10",
            "new_arrival_on" => "2027-04-10",
            "expected_revision" => 1
          })
        ])

      assert Enum.at(response["results"], 3) == %{
               "operation_id" => "op-move-new",
               "status" => "applied",
               "group_id" => "group-new",
               "new_arrival_on" => "2027-04-10",
               "new_departure_on" => "2027-04-13",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-11",
               "revision" => 2
             }

      assert %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-01"
             } = read_group("group-old")["data"]

      assert %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-11",
               "arrival_on" => "2027-04-10"
             } = read_group("group-new")["data"]

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = read_group("group-advance")["data"]
    end

    test "uses the fixed flexible policy window when cancelling" do
      response =
        submit_batch([
          open_group_operation(%{
            "operation_id" => "op-open-old",
            "group_id" => "group-old",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment_operation(%{
            "operation_id" => "op-pay-old",
            "group_id" => "group-old",
            "amount_cents" => 1_000
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-old",
            "group_id" => "group-old",
            "occurred_on" => "2027-03-01"
          }),
          open_group_operation(%{
            "operation_id" => "op-open-new",
            "group_id" => "group-new",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment_operation(%{
            "operation_id" => "op-pay-new",
            "group_id" => "group-new",
            "amount_cents" => 1_000
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-new",
            "group_id" => "group-new",
            "occurred_on" => "2027-02-14"
          })
        ])

      assert Enum.at(response["results"], 2) == %{
               "operation_id" => "op-cancel-old",
               "status" => "applied",
               "group_id" => "group-old",
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert Enum.at(response["results"], 5) == %{
               "operation_id" => "op-cancel-new",
               "status" => "applied",
               "group_id" => "group-new",
               "refunded_cents" => 0,
               "retained_cents" => 1_000,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 1_000,
                 "cash_retained_cents" => 1_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "issues hotel credit for refundable cash cancellation and expires it from reads" do
      response =
        submit_batch([
          open_group_operation(%{
            "operation_id" => "op-open",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 19_500}),
          cancel_operation(%{
            "operation_id" => "op-cancel",
            "occurred_on" => "2027-02-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert Enum.at(response["results"], 2) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 21_450,
               "revision" => 3
             }

      assert read_guest_credit("guest-22", %{"on" => "2027-02-01"}) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 21_450,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel",
                     "remaining_cents" => 21_450,
                     "expires_on" => "2028-02-02"
                   }
                 ]
               }
             }

      assert read_ledger(%{"on" => "2027-02-01"}) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 19_500,
                 "credit_liability_cents" => 21_450
               }
             }

      assert read_guest_credit("guest-22", %{"on" => "2028-02-02"}) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      assert read_ledger(%{"on" => "2028-02-02"})["data"]["credit_liability_cents"] == 0
    end

    test "applies credit by expiry and source id, then restores original lots on refundable cancellation" do
      submit_batch([
        open_group_operation(%{
          "operation_id" => "op-open-b",
          "group_id" => "source-b",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay-b",
          "group_id" => "source-b",
          "amount_cents" => 1_000
        }),
        cancel_operation(%{
          "operation_id" => "cancel-b",
          "group_id" => "source-b",
          "occurred_on" => "2027-01-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-a",
          "group_id" => "source-a",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay-a",
          "group_id" => "source-a",
          "amount_cents" => 1_000
        }),
        cancel_operation(%{
          "operation_id" => "cancel-a",
          "group_id" => "source-a",
          "occurred_on" => "2027-01-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-target",
          "group_id" => "target",
          "occurred_on" => "2027-01-06",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        })
      ])

      response =
        submit_batch([
          hotel_credit_operation(%{
            "operation_id" => "op-credit-target",
            "group_id" => "target",
            "occurred_on" => "2027-01-07",
            "amount_cents" => 1_500,
            "expected_revision" => 1
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-credit-target",
                   "status" => "applied",
                   "group_id" => "target",
                   "amount_cents" => 1_500,
                   "outstanding_deposit_cents" => 18_000,
                   "revision" => 2
                 }
               ]
             }

      assert read_group("target")["data"]
             |> Map.take(["deposit_paid_cents", "cash_paid_cents", "credit_paid_cents"]) ==
               %{
                 "deposit_paid_cents" => 1_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1_500
               }

      assert read_guest_credit("guest-22", %{"on" => "2027-01-07"}) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 700,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 700,
                     "expires_on" => "2028-01-06"
                   }
                 ]
               }
             }

      assert read_ledger(%{"on" => "2027-01-07"})["data"]["credit_liability_cents"] == 2_200

      submit_batch([
        cancel_operation(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "target",
          "occurred_on" => "2027-01-08",
          "expected_revision" => 2
        })
      ])

      assert read_guest_credit("guest-22", %{"on" => "2027-01-08"}) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 2_200,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2028-01-06"
                   },
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2028-01-06"
                   }
                 ]
               }
             }

      assert read_ledger(%{"on" => "2027-01-08"})["data"]["credit_liability_cents"] == 2_200
    end

    test "does not restore applied credit after the original lot has expired" do
      submit_batch([
        open_group_operation(%{
          "operation_id" => "op-open-source",
          "group_id" => "source",
          "occurred_on" => "2026-12-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay-source",
          "group_id" => "source",
          "amount_cents" => 1_000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-source",
          "group_id" => "source",
          "occurred_on" => "2027-01-01",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-target",
          "group_id" => "target",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        }),
        hotel_credit_operation(%{
          "operation_id" => "op-credit-target",
          "group_id" => "target",
          "occurred_on" => "2027-01-02",
          "amount_cents" => 1_100
        })
      ])

      assert read_guest_credit("guest-22", %{"on" => "2028-01-02"}) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      assert read_ledger(%{"on" => "2028-01-03"})["data"]["credit_liability_cents"] == 1_100

      response =
        submit_batch([
          cancel_operation(%{
            "operation_id" => "op-cancel-target",
            "group_id" => "target",
            "occurred_on" => "2028-01-03"
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel-target",
                   "status" => "applied",
                   "group_id" => "target",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert read_ledger(%{"on" => "2028-01-03"})["data"]["credit_liability_cents"] == 0
    end

    test "rejects unavailable refund methods and checks stale revisions before credit rules" do
      submit_batch([
        open_group_operation(%{
          "operation_id" => "op-open",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        cash_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1_000})
      ])

      response =
        submit_batch([
          cancel_operation(%{
            "operation_id" => "op-stale-cancel",
            "occurred_on" => "2027-02-20",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          }),
          cancel_operation(%{
            "operation_id" => "op-bad-method",
            "occurred_on" => "2027-02-20",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          }),
          hotel_credit_operation(%{
            "operation_id" => "op-stale-credit",
            "amount_cents" => 1,
            "expected_revision" => 1
          }),
          hotel_credit_operation(%{
            "operation_id" => "op-insufficient-credit",
            "amount_cents" => 1,
            "expected_revision" => 2
          }),
          cancel_operation(%{
            "operation_id" => "op-cancel-cash",
            "occurred_on" => "2027-02-20",
            "expected_revision" => 2
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-stale-cancel",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-bad-method",
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 },
                 %{
                   "operation_id" => "op-stale-credit",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-insufficient-credit",
                   "status" => "rejected",
                   "code" => "insufficient_credit"
                 },
                 %{
                   "operation_id" => "op-cancel-cash",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 0,
                   "retained_cents" => 1_000,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert read_group("group-81")["data"]["revision"] == 3
      assert read_ledger()["data"]["cash_retained_cents"] == 1_000
    end

    test "replays an identical applied operation without reapplying domain changes" do
      operation = open_group_operation()

      response = submit_batch([operation])
      retry_response = submit_batch([operation])

      assert retry_response == response

      assert read_group("group-81")["data"]
             |> Map.take(["revision", "deposit_paid_cents", "outstanding_deposit_cents"]) ==
               %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
    end

    test "replays a stored rejection even after later state would make it valid" do
      operation =
        cash_payment_operation(%{
          "operation_id" => "op-pay-before-open",
          "group_id" => "group-later",
          "amount_cents" => 500
        })

      response = submit_batch([operation])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay-before-open",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "group-later"
                 }
               ]
             }

      submit_batch([
        open_group_operation(%{"operation_id" => "op-open-later", "group_id" => "group-later"})
      ])

      assert submit_batch([operation]) == response
      assert read_group("group-later")["data"]["deposit_paid_cents"] == 0
      assert read_operation("op-pay-before-open") == %{"data" => hd(response["results"])}
    end

    test "rejects operation id reuse with a different payload and preserves the original result" do
      submit_batch([open_group_operation()])

      stale_operation =
        cash_payment_operation(%{
          "operation_id" => "op-stale-then-corrected",
          "amount_cents" => 500,
          "expected_revision" => 0
        })

      response = submit_batch([stale_operation])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-stale-then-corrected",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 }
               ]
             }

      corrected_operation = Map.put(stale_operation, "expected_revision", 1)

      assert submit_batch([corrected_operation]) == %{
               "results" => [
                 %{
                   "operation_id" => "op-stale-then-corrected",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      assert read_group("group-81")["data"]
             |> Map.take(["revision", "deposit_paid_cents"]) ==
               %{"revision" => 1, "deposit_paid_cents" => 0}

      assert read_operation("op-stale-then-corrected") == %{"data" => hd(response["results"])}
    end

    test "canonicalizes object key order while preserving array order and audit content" do
      first_payload =
        ~s({"operations":[{"operation_id":"op-json-order","type":"adjust_group","nested":{"a":1,"b":[2,3]},"flag":true}]})

      reordered_payload =
        ~s({"operations":[{"flag":true,"nested":{"b":[2,3],"a":1},"type":"adjust_group","operation_id":"op-json-order"}]})

      changed_array_payload =
        ~s({"operations":[{"operation_id":"op-json-order","type":"adjust_group","nested":{"a":1,"b":[3,2]},"flag":true}]})

      response = raw_submit_batch(first_payload)

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-json-order",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 }
               ]
             }

      assert raw_submit_batch(reordered_payload) == response

      assert raw_submit_batch(changed_array_payload) == %{
               "results" => [
                 %{
                   "operation_id" => "op-json-order",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      partner_operation = Repo.get_by!(PartnerOperation, operation_id: "op-json-order")

      assert partner_operation.operation_type == "adjust_group"

      assert Jason.decode!(partner_operation.submitted_json) == %{
               "operation_id" => "op-json-order",
               "type" => "adjust_group",
               "nested" => %{"a" => 1, "b" => [2, 3]},
               "flag" => true
             }
    end

    test "preserves first committed operation order in durable records" do
      submit_batch([
        open_group_operation(%{"operation_id" => "op-first", "group_id" => "first-group"}),
        open_group_operation(%{"operation_id" => "op-second", "group_id" => "second-group"})
      ])

      operation_ids =
        PartnerOperation
        |> where([operation], operation.operation_id in ["op-first", "op-second"])
        |> order_by([operation], asc: operation.id)
        |> select([operation], operation.operation_id)
        |> Repo.all()

      assert operation_ids == ["op-first", "op-second"]
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored operation result" do
      response = submit_batch([open_group_operation()])

      assert read_operation("op-open") == %{"data" => hd(response["results"])}
    end

    test "returns operation_not_found for missing operations" do
      assert read_missing_operation("missing-op") == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp submit_batch(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp raw_submit_batch(json_payload) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", json_payload)
    |> json_response(200)
  end

  defp read_group(group_id) do
    build_conn()
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp read_missing_group(group_id) do
    build_conn()
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(404)
  end

  defp read_ledger(params \\ %{}) do
    build_conn()
    |> get(~p"/api/v1/ledger", params)
    |> json_response(200)
  end

  defp read_guest_credit(guest_id, params) do
    build_conn()
    |> get(~p"/api/v1/guests/#{guest_id}/credit", params)
    |> json_response(200)
  end

  defp read_operation(operation_id) do
    build_conn()
    |> get(~p"/api/v1/operations/#{operation_id}")
    |> json_response(200)
  end

  defp read_missing_operation(operation_id) do
    build_conn()
    |> get(~p"/api/v1/operations/#{operation_id}")
    |> json_response(404)
  end

  defp open_group_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
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

  defp cash_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-17"
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp hotel_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1
      },
      overrides
    )
  end
end
