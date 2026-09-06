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
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "lodging_total_cents" => 45_000,
                     "deposit_due_cents" => 9_000,
                     "status" => "active",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "lodging_total_cents" => 52_500,
                     "deposit_due_cents" => 10_500,
                     "status" => "active",
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

      assert read_ledger() == %{
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
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15_000,
                   "lodging_total_cents" => 45_000,
                   "deposit_due_cents" => 9_000,
                   "status" => "cancelled",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17_500,
                   "lodging_total_cents" => 52_500,
                   "deposit_due_cents" => 10_500,
                   "status" => "cancelled",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19_500,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 21_450,
                 "credit_shortfall_cents" => 0
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

    test "transfers cash and credit between active groups without changing ledger totals" do
      submit_batch([
        open_group_operation(%{
          "operation_id" => "op-open-origin",
          "group_id" => "credit-origin",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay-origin",
          "group_id" => "credit-origin",
          "occurred_on" => "2027-01-02",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-origin",
          "group_id" => "credit-origin",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }),
        open_group_operation(%{
          "operation_id" => "op-open-source",
          "group_id" => "source",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-16",
          "rooms" => [
            %{"room_id" => "source-a", "nightly_rate_cents" => 5_000},
            %{"room_id" => "source-b", "nightly_rate_cents" => 10_000},
            %{"room_id" => "source-c", "nightly_rate_cents" => 15_000}
          ]
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay-source",
          "group_id" => "source",
          "occurred_on" => "2027-02-02",
          "amount_cents" => 2_500,
          "expected_revision" => 1
        }),
        hotel_credit_operation(%{
          "operation_id" => "op-credit-source",
          "group_id" => "source",
          "occurred_on" => "2027-02-02",
          "amount_cents" => 1_000,
          "expected_revision" => 2
        }),
        open_group_operation(%{
          "operation_id" => "op-open-dest",
          "group_id" => "dest",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-16",
          "rooms" => [
            %{"room_id" => "dest-a", "nightly_rate_cents" => 7_500},
            %{"room_id" => "dest-b", "nightly_rate_cents" => 12_500}
          ]
        })
      ])

      ledger_before_transfer = read_ledger(%{"on" => "2027-02-02"})

      transfer =
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer",
          "source_group_id" => "source",
          "destination_group_id" => "dest",
          "amount_cents" => 1_800,
          "expected_revision" => 3,
          "destination_expected_revision" => 1
        })

      response = submit_batch([transfer])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-transfer",
                   "status" => "applied",
                   "source_group_id" => "source",
                   "destination_group_id" => "dest",
                   "amount_cents" => 1_800,
                   "source_outstanding_deposit_cents" => 4_300,
                   "destination_outstanding_deposit_cents" => 2_200,
                   "source_revision" => 4,
                   "destination_revision" => 2
                 }
               ]
             }

      assert submit_batch([transfer]) == response
      assert read_ledger(%{"on" => "2027-02-02"}) == ledger_before_transfer

      assert read_group("source")["data"]
             |> Map.take([
               "revision",
               "deposit_paid_cents",
               "cash_paid_cents",
               "credit_paid_cents",
               "outstanding_deposit_cents"
             ]) ==
               %{
                 "revision" => 4,
                 "deposit_paid_cents" => 1_700,
                 "cash_paid_cents" => 1_700,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 4_300
               }

      assert read_group("source")["data"]["rooms"] == [
               %{
                 "room_id" => "source-a",
                 "nightly_rate_cents" => 5_000,
                 "lodging_total_cents" => 5_000,
                 "deposit_due_cents" => 1_000,
                 "status" => "active",
                 "cash_paid_cents" => 1_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "source-b",
                 "nightly_rate_cents" => 10_000,
                 "lodging_total_cents" => 10_000,
                 "deposit_due_cents" => 2_000,
                 "status" => "active",
                 "cash_paid_cents" => 700,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "source-c",
                 "nightly_rate_cents" => 15_000,
                 "lodging_total_cents" => 15_000,
                 "deposit_due_cents" => 3_000,
                 "status" => "active",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]

      assert read_group("dest")["data"]
             |> Map.take([
               "revision",
               "deposit_paid_cents",
               "cash_paid_cents",
               "credit_paid_cents",
               "outstanding_deposit_cents"
             ]) ==
               %{
                 "revision" => 2,
                 "deposit_paid_cents" => 1_800,
                 "cash_paid_cents" => 800,
                 "credit_paid_cents" => 1_000,
                 "outstanding_deposit_cents" => 2_200
               }

      assert read_group("dest")["data"]["rooms"] == [
               %{
                 "room_id" => "dest-a",
                 "nightly_rate_cents" => 7_500,
                 "lodging_total_cents" => 7_500,
                 "deposit_due_cents" => 1_500,
                 "status" => "active",
                 "cash_paid_cents" => 500,
                 "credit_paid_cents" => 1_000
               },
               %{
                 "room_id" => "dest-b",
                 "nightly_rate_cents" => 12_500,
                 "lodging_total_cents" => 12_500,
                 "deposit_due_cents" => 2_500,
                 "status" => "active",
                 "cash_paid_cents" => 300,
                 "credit_paid_cents" => 0
               }
             ]

      assert read_payment("op-pay-source") == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-source",
                 "original_group_id" => "source",
                 "recorded_cents" => 2_500,
                 "held_cents" => 2_500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "dest", "amount_cents" => 800},
                   %{"group_id" => "source", "amount_cents" => 1_700}
                 ]
               }
             }

      refute Map.has_key?(read_payment("op-pay-origin")["data"], "held_by_group")

      cancel_response =
        submit_batch([
          cancel_operation(%{
            "operation_id" => "op-cancel-dest",
            "group_id" => "dest",
            "occurred_on" => "2027-02-03",
            "expected_revision" => 2
          })
        ])

      assert cancel_response == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel-dest",
                   "status" => "applied",
                   "group_id" => "dest",
                   "refunded_cents" => 800,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert read_guest_credit("guest-22", %{"on" => "2027-02-03"}) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 1_100,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-origin",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2028-02-02"
                   }
                 ]
               }
             }

      assert read_payment("op-pay-source") == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-source",
                 "original_group_id" => "source",
                 "recorded_cents" => 2_500,
                 "held_cents" => 1_700,
                 "refunded_cents" => 800,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "source", "amount_cents" => 1_700}
                 ]
               }
             }

      assert read_ledger(%{"on" => "2027-02-03"})["data"]
             |> Map.take([
               "cash_held_cents",
               "cash_refunded_cents",
               "cash_converted_to_credit_cents",
               "credit_liability_cents"
             ]) ==
               %{
                 "cash_held_cents" => 1_700,
                 "cash_refunded_cents" => 800,
                 "cash_converted_to_credit_cents" => 1_000,
                 "credit_liability_cents" => 1_100
               }
    end

    test "rejects invalid deposit transfers in required order" do
      submit_batch([
        open_group_operation(%{"operation_id" => "op-open-source", "group_id" => "source"}),
        cash_payment_operation(%{
          "operation_id" => "op-pay-source",
          "group_id" => "source",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }),
        open_group_operation(%{"operation_id" => "op-open-dest", "group_id" => "dest"}),
        open_group_operation(%{
          "operation_id" => "op-open-other",
          "group_id" => "other",
          "guest_id" => "guest-33"
        }),
        open_group_operation(%{"operation_id" => "op-open-inactive", "group_id" => "inactive"}),
        cancel_operation(%{
          "operation_id" => "op-cancel-inactive",
          "group_id" => "inactive",
          "occurred_on" => "2026-10-05",
          "expected_revision" => 1
        }),
        open_group_operation(%{
          "operation_id" => "op-open-small-dest",
          "group_id" => "small-dest",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "tiny-room", "nightly_rate_cents" => 5}
          ]
        })
      ])

      response =
        submit_batch([
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-missing-source",
            "source_group_id" => "missing-source",
            "destination_group_id" => "missing-dest",
            "amount_cents" => 1
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-missing-dest",
            "source_group_id" => "source",
            "destination_group_id" => "missing-dest",
            "amount_cents" => 1
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-stale-source",
            "source_group_id" => "source",
            "destination_group_id" => "dest",
            "amount_cents" => 0,
            "expected_revision" => 1,
            "destination_expected_revision" => 1
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-stale-dest",
            "source_group_id" => "source",
            "destination_group_id" => "dest",
            "amount_cents" => 0,
            "expected_revision" => 2,
            "destination_expected_revision" => 0
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-same",
            "source_group_id" => "source",
            "destination_group_id" => "source",
            "amount_cents" => 1,
            "expected_revision" => 2
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-different-guests",
            "source_group_id" => "source",
            "destination_group_id" => "other",
            "amount_cents" => 1
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-inactive-source",
            "source_group_id" => "inactive",
            "destination_group_id" => "dest",
            "amount_cents" => 1
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-inactive-dest",
            "source_group_id" => "source",
            "destination_group_id" => "inactive",
            "amount_cents" => 1
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-invalid-amount",
            "source_group_id" => "source",
            "destination_group_id" => "dest",
            "amount_cents" => 0
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-too-much-held",
            "source_group_id" => "source",
            "destination_group_id" => "dest",
            "amount_cents" => 1_001
          }),
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-too-much-dest",
            "source_group_id" => "source",
            "destination_group_id" => "small-dest",
            "amount_cents" => 2
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-transfer-missing-source",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "missing-source"
                 },
                 %{
                   "operation_id" => "op-transfer-missing-dest",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "missing-dest"
                 },
                 %{
                   "operation_id" => "op-transfer-stale-source",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "source",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-transfer-stale-dest",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "dest",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{
                   "operation_id" => "op-transfer-same",
                   "status" => "rejected",
                   "code" => "invalid_transfer"
                 },
                 %{
                   "operation_id" => "op-transfer-different-guests",
                   "status" => "rejected",
                   "code" => "invalid_transfer"
                 },
                 %{
                   "operation_id" => "op-transfer-inactive-source",
                   "status" => "rejected",
                   "code" => "group_not_active",
                   "group_id" => "inactive"
                 },
                 %{
                   "operation_id" => "op-transfer-inactive-dest",
                   "status" => "rejected",
                   "code" => "group_not_active",
                   "group_id" => "inactive"
                 },
                 %{
                   "operation_id" => "op-transfer-invalid-amount",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "op-transfer-too-much-held",
                   "status" => "rejected",
                   "code" => "transfer_exceeds_held_funding"
                 },
                 %{
                   "operation_id" => "op-transfer-too-much-dest",
                   "status" => "rejected",
                   "code" => "transfer_exceeds_outstanding"
                 }
               ]
             }

      assert read_group("source")["data"]["revision"] == 2
      assert read_group("dest")["data"]["revision"] == 1
      assert read_payment("op-pay-source")["data"]["held_cents"] == 1_000
    end

    test "exposes room allocations and cancels selected rooms in original order" do
      cancel_rooms =
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-rooms",
          "occurred_on" => "2027-02-01",
          "room_ids" => ["room-c", "room-a"],
          "expected_revision" => 2
        })

      response =
        submit_batch([
          open_group_operation(%{
            "operation_id" => "op-open",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-16",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 5_000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 10_000},
              %{"room_id" => "room-c", "nightly_rate_cents" => 15_000}
            ]
          }),
          cash_payment_operation(%{
            "operation_id" => "op-pay",
            "amount_cents" => 4_000,
            "expected_revision" => 1
          }),
          cancel_rooms
        ])

      assert Enum.at(response["results"], 2) == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a", "room-c"],
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert submit_batch([cancel_rooms]) == %{"results" => [Enum.at(response["results"], 2)]}

      assert read_group("group-81")["data"] == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 3,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2027-03-15",
               "departure_on" => "2027-03-16",
               "rate_plan" => "flexible",
               "status" => "active",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-01",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 5_000,
                   "lodging_total_cents" => 5_000,
                   "deposit_due_cents" => 1_000,
                   "status" => "cancelled",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 10_000,
                   "lodging_total_cents" => 10_000,
                   "deposit_due_cents" => 2_000,
                   "status" => "active",
                   "cash_paid_cents" => 2_000,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-c",
                   "nightly_rate_cents" => 15_000,
                   "lodging_total_cents" => 15_000,
                   "deposit_due_cents" => 3_000,
                   "status" => "cancelled",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2_000,
               "deposit_paid_cents" => 2_000,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 2_000,
                 "cash_refunded_cents" => 2_000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "reduces a cash payment in reverse fill order and reconciles its disposition" do
      reduction =
        reduce_cash_payment_operation(%{
          "operation_id" => "op-reduce-pay-1",
          "payment_operation_id" => "op-pay-1",
          "amount_cents" => 2_000,
          "expected_revision" => 3
        })

      response =
        submit_batch([
          open_group_operation(),
          cash_payment_operation(%{
            "operation_id" => "op-pay-1",
            "amount_cents" => 10_000,
            "expected_revision" => 1
          }),
          cash_payment_operation(%{
            "operation_id" => "op-pay-2",
            "amount_cents" => 5_000,
            "expected_revision" => 2
          }),
          reduction
        ])

      assert Enum.at(response["results"], 3) == %{
               "operation_id" => "op-reduce-pay-1",
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 6_500,
               "revision" => 4
             }

      assert submit_batch([reduction]) == %{"results" => [Enum.at(response["results"], 3)]}

      assert read_group("group-81")["data"]["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "lodging_total_cents" => 45_000,
                 "deposit_due_cents" => 9_000,
                 "status" => "active",
                 "cash_paid_cents" => 8_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "lodging_total_cents" => 52_500,
                 "deposit_due_cents" => 10_500,
                 "status" => "active",
                 "cash_paid_cents" => 5_000,
                 "credit_paid_cents" => 0
               }
             ]

      assert read_payment("op-pay-1") == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-1",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10_000,
                 "held_cents" => 8_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 2_000,
                 "charged_back_cents" => 0
               }
             }

      assert read_ledger()["data"]
             |> Map.take(["cash_held_cents", "cash_reduced_cents"]) ==
               %{"cash_held_cents" => 13_000, "cash_reduced_cents" => 2_000}
    end

    test "rejects unreducible payment reductions with stable codes" do
      submit_batch([
        open_group_operation(),
        cash_payment_operation(%{
          "operation_id" => "op-pay",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        })
      ])

      response =
        submit_batch([
          reduce_cash_payment_operation(%{
            "operation_id" => "op-reduce-missing",
            "payment_operation_id" => "missing-pay",
            "amount_cents" => 1
          }),
          reduce_cash_payment_operation(%{
            "operation_id" => "op-reduce-open",
            "payment_operation_id" => "op-open",
            "amount_cents" => 1
          }),
          reduce_cash_payment_operation(%{
            "operation_id" => "op-reduce-stale",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1,
            "expected_revision" => 1
          }),
          reduce_cash_payment_operation(%{
            "operation_id" => "op-reduce-invalid",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 0,
            "expected_revision" => 2
          }),
          reduce_cash_payment_operation(%{
            "operation_id" => "op-reduce-too-much",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1_001,
            "expected_revision" => 2
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-reduce-missing",
                   "status" => "rejected",
                   "code" => "operation_not_found"
                 },
                 %{
                   "operation_id" => "op-reduce-open",
                   "status" => "rejected",
                   "code" => "payment_not_reducible"
                 },
                 %{
                   "operation_id" => "op-reduce-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-reduce-invalid",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "op-reduce-too-much",
                   "status" => "rejected",
                   "code" => "reduction_exceeds_held_cash"
                 }
               ]
             }

      assert read_payment("op-pay")["data"]
             |> Map.take(["held_cents", "reduced_cents"]) ==
               %{"held_cents" => 1_000, "reduced_cents" => 0}
    end

    test "reductions and chargebacks follow transferred cash across groups" do
      submit_batch([
        open_group_operation(%{
          "operation_id" => "op-open-source",
          "group_id" => "source",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "source-a", "nightly_rate_cents" => 5_000},
            %{"room_id" => "source-b", "nightly_rate_cents" => 10_000}
          ]
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay",
          "group_id" => "source",
          "amount_cents" => 3_000,
          "expected_revision" => 1
        }),
        open_group_operation(%{
          "operation_id" => "op-open-dest",
          "group_id" => "dest",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "dest-a", "nightly_rate_cents" => 5_000},
            %{"room_id" => "dest-b", "nightly_rate_cents" => 10_000}
          ]
        }),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer",
          "source_group_id" => "source",
          "destination_group_id" => "dest",
          "amount_cents" => 1_500,
          "expected_revision" => 2,
          "destination_expected_revision" => 1
        })
      ])

      reduce_response =
        submit_batch([
          reduce_cash_payment_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1_000,
            "expected_revision" => 3
          })
        ])

      assert reduce_response == %{
               "results" => [
                 %{
                   "operation_id" => "op-reduce",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "source",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 1_500,
                   "revision" => 4
                 }
               ]
             }

      assert read_group("source")["data"]
             |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
               %{
                 "revision" => 4,
                 "cash_paid_cents" => 1_500,
                 "outstanding_deposit_cents" => 1_500
               }

      assert read_group("dest")["data"]
             |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
               %{
                 "revision" => 3,
                 "cash_paid_cents" => 500,
                 "outstanding_deposit_cents" => 2_500
               }

      assert read_payment("op-pay") == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "source",
                 "recorded_cents" => 3_000,
                 "held_cents" => 2_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1_000,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "dest", "amount_cents" => 500},
                   %{"group_id" => "source", "amount_cents" => 1_500}
                 ]
               }
             }

      chargeback_response =
        submit_batch([
          charge_back_payment_operation(%{
            "operation_id" => "op-chargeback",
            "payment_operation_id" => "op-pay",
            "expected_revision" => 4
          })
        ])

      assert chargeback_response == %{
               "results" => [
                 %{
                   "operation_id" => "op-chargeback",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "source",
                   "charged_back_cents" => 2_000,
                   "outstanding_deposit_cents" => 3_000,
                   "revision" => 5
                 }
               ]
             }

      assert read_group("source")["data"]
             |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
               %{
                 "revision" => 5,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 3_000
               }

      assert read_group("dest")["data"]
             |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
               %{
                 "revision" => 4,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 3_000
               }

      assert read_payment("op-pay") == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "source",
                 "recorded_cents" => 3_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1_000,
                 "charged_back_cents" => 2_000,
                 "held_by_group" => []
               }
             }

      assert read_ledger()["data"]
             |> Map.take(["cash_held_cents", "cash_reduced_cents", "cash_charged_back_cents"]) ==
               %{
                 "cash_held_cents" => 0,
                 "cash_reduced_cents" => 1_000,
                 "cash_charged_back_cents" => 2_000
               }
    end

    test "charges back converted cash and absorbs returned shortfall before credit availability" do
      submit_batch([
        open_group_operation(%{
          "operation_id" => "op-open-source",
          "group_id" => "source",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        cash_payment_operation(%{
          "operation_id" => "op-pay-source",
          "group_id" => "source",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-source",
          "group_id" => "source",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }),
        open_group_operation(%{
          "operation_id" => "op-open-target",
          "group_id" => "target",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        hotel_credit_operation(%{
          "operation_id" => "op-credit-target",
          "group_id" => "target",
          "occurred_on" => "2027-02-02",
          "amount_cents" => 1_100,
          "expected_revision" => 1
        })
      ])

      response =
        submit_batch([
          charge_back_payment_operation(%{
            "operation_id" => "op-chargeback-source",
            "payment_operation_id" => "op-pay-source",
            "expected_revision" => 3
          })
        ])

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-chargeback-source",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay-source",
                   "group_id" => "source",
                   "charged_back_cents" => 1_000,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 4
                 }
               ]
             }

      assert read_group("target")["data"]["revision"] == 2

      assert read_payment("op-pay-source") == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-source",
                 "original_group_id" => "source",
                 "recorded_cents" => 1_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 1_000
               }
             }

      assert read_ledger(%{"on" => "2027-02-02"})["data"]
             |> Map.take([
               "cash_converted_to_credit_cents",
               "cash_charged_back_cents",
               "credit_liability_cents",
               "credit_shortfall_cents"
             ]) ==
               %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 1_000,
                 "credit_liability_cents" => 1_100,
                 "credit_shortfall_cents" => 1_100
               }

      assert read_guest_credit("guest-22", %{"on" => "2027-02-02"})["data"]["available_cents"] ==
               0

      submit_batch([
        cancel_operation(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "target",
          "occurred_on" => "2027-02-03",
          "expected_revision" => 2
        })
      ])

      assert read_guest_credit("guest-22", %{"on" => "2027-02-03"})["data"]["available_cents"] ==
               0

      assert read_ledger(%{"on" => "2027-02-03"})["data"]
             |> Map.take(["credit_liability_cents", "credit_shortfall_cents"]) ==
               %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}
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

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns operation_not_found for missing payment operations" do
      assert read_missing_payment("missing-pay") == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end

    test "rejects existing operations that are not applied cash payments" do
      submit_batch([open_group_operation()])

      assert read_unreconcilable_payment("op-open") == %{
               "error" => %{"code" => "payment_not_reconcilable"}
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

  defp read_payment(payment_operation_id) do
    build_conn()
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
  end

  defp read_missing_payment(payment_operation_id) do
    build_conn()
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(404)
  end

  defp read_unreconcilable_payment(payment_operation_id) do
    build_conn()
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(422)
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

  defp cancel_rooms_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp reduce_cash_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-04",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1
      },
      overrides
    )
  end

  defp charge_back_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-04",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp transfer_deposit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-04",
        "source_group_id" => "source",
        "destination_group_id" => "dest",
        "amount_cents" => 1
      },
      overrides
    )
  end
end
