defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

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
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
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
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19_500,
                 "cash_retained_cents" => 0
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
               "revision" => 3
             }

      assert read_ledger() == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 117_000
               }
             }
    end
  end

  defp submit_batch(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
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

  defp read_ledger do
    build_conn()
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
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
end
