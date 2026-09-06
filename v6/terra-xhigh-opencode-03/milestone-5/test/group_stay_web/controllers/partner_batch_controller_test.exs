defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
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

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp room(
         room_id,
         nightly_rate_cents,
         lodging_total_cents,
         deposit_due_cents,
         cash_paid_cents \\ 0,
         credit_paid_cents \\ 0,
         status \\ "active"
       ) do
    %{
      "room_id" => room_id,
      "nightly_rate_cents" => nightly_rate_cents,
      "status" => status,
      "lodging_total_cents" => lodging_total_cents,
      "deposit_due_cents" => deposit_due_cents,
      "cash_paid_cents" => cash_paid_cents,
      "credit_paid_cents" => credit_paid_cents
    }
  end

  defp ledger_data(overrides) do
    Map.merge(
      %{
        "cash_held_cents" => 0,
        "cash_refunded_cents" => 0,
        "cash_retained_cents" => 0,
        "cash_converted_to_credit_cents" => 0,
        "cash_reduced_cents" => 0,
        "cash_charged_back_cents" => 0,
        "credit_liability_cents" => 0,
        "credit_shortfall_cents" => 0
      },
      overrides
    )
  end

  test "opens a group, applies later operations in order, and returns the group", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "payment-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 5_000
        }
      ])
      |> json_response(200)

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "payment-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           }

    group = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)

    assert group == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "revision" => 2,
               "rooms" => [
                 room("room-a", 15_000, 45_000, 9_000, 5_000),
                 room("room-b", 17_500, 52_500, 10_500)
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 5_000,
               "cash_paid_cents" => 5_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 14_500
             }
           }

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == %{
             "data" => ledger_data(%{"cash_held_cents" => 5_000})
           }
  end

  test "uses revision checks before validation and continues after rejections", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "payment-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "stale-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "payment-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 500,
          "expected_revision" => 2
        },
        %{
          "operation_id" => "missing",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "missing-group",
          "amount_cents" => 1,
          "expected_revision" => 9
        }
      ])
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             },
             %{
               "operation_id" => "payment-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 18_500,
               "revision" => 2
             },
             %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             },
             %{
               "operation_id" => "payment-2",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 18_000,
               "revision" => 3
             },
             %{
               "operation_id" => "missing",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "missing-group"
             }
           ]
  end

  test "reschedules active stays while keeping their duration and price", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "reschedule-1",
          "type" => "reschedule_group",
          "group_id" => "group-81",
          "occurred_on" => "2026-10-04",
          "new_arrival_on" => "2026-12-20"
        },
        %{
          "operation_id" => "bad-reschedule",
          "type" => "reschedule_group",
          "group_id" => "group-81",
          "occurred_on" => "2026-10-04",
          "new_arrival_on" => "2026-10-04"
        }
      ])
      |> json_response(200)

    assert response["results"] |> Enum.at(1) == %{
             "operation_id" => "reschedule-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2026-12-20",
             "new_departure_on" => "2026-12-23",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-12-06",
             "revision" => 2
           }

    assert response["results"] |> Enum.at(2) == %{
             "operation_id" => "bad-reschedule",
             "status" => "rejected",
             "code" => "invalid_stay",
             "group_id" => "group-81"
           }

    group = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["data"]["lodging_total_cents"] == 97_500
    assert group["data"]["deposit_due_cents"] == 19_500
    assert group["data"]["revision"] == 2
  end

  test "settles flexible and advance-purchase payments in the ledger", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "flex-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 5_000
        },
        %{
          "operation_id" => "flex-cancel",
          "type" => "cancel_group",
          "group_id" => "group-81",
          "occurred_on" => "2026-11-26"
        },
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "group-advance",
          "rate_plan" => "advance_purchase"
        }),
        %{
          "operation_id" => "advance-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-advance",
          "amount_cents" => 20_000
        },
        %{
          "operation_id" => "advance-cancel",
          "type" => "cancel_group",
          "group_id" => "group-advance",
          "occurred_on" => "2026-10-04"
        }
      ])
      |> json_response(200)

    assert response["results"] |> Enum.at(2) == %{
             "operation_id" => "flex-cancel",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 5_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert response["results"] |> Enum.at(5) == %{
             "operation_id" => "advance-cancel",
             "status" => "applied",
             "group_id" => "group-advance",
             "refunded_cents" => 0,
             "retained_cents" => 20_000,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == %{
             "data" =>
               ledger_data(%{"cash_refunded_cents" => 5_000, "cash_retained_cents" => 20_000})
           }

    assert get(build_conn(), "/api/v1/groups/group-81") |> json_response(200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "cancelled",
               "revision" => 3,
               "rooms" => [
                 room("room-a", 15_000, 45_000, 0, 0, 0, "cancelled"),
                 room("room-b", 17_500, 52_500, 0, 0, 0, "cancelled")
               ],
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           }
  end

  test "rejects invalid operations without changing later outcomes", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(%{"operation_id" => "bad-open", "departure_on" => "2026-12-10"}),
        open_operation(),
        open_operation(%{"operation_id" => "duplicate"}),
        %{
          "operation_id" => "too-much",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 19_501
        },
        %{"operation_id" => "unknown", "type" => "unknown_operation"},
        %{
          "operation_id" => "valid-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 19_500
        }
      ])
      |> json_response(200)

    assert response["results"] |> Enum.map(&Map.take(&1, ["operation_id", "status", "code"])) == [
             %{"operation_id" => "bad-open", "status" => "rejected", "code" => "invalid_stay"},
             %{"operation_id" => "open-1", "status" => "applied"},
             %{
               "operation_id" => "duplicate",
               "status" => "rejected",
               "code" => "group_already_exists"
             },
             %{
               "operation_id" => "too-much",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             },
             %{
               "operation_id" => "unknown",
               "status" => "rejected",
               "code" => "invalid_operation"
             },
             %{"operation_id" => "valid-payment", "status" => "applied"}
           ]

    group = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["data"]["deposit_paid_cents"] == 19_500
    assert group["data"]["revision"] == 2
  end

  test "validates common fields and computes flexible deposits per room", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(%{
          "group_id" => "rounding-group",
          "rooms" => [
            %{"room_id" => "one", "nightly_rate_cents" => 3},
            %{"room_id" => "two", "nightly_rate_cents" => 3}
          ],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        }),
        %{
          "operation_id" => "missing-date",
          "type" => "record_cash_payment",
          "group_id" => "rounding-group",
          "amount_cents" => 1
        },
        %{
          "operation_id" => 123,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "rounding-group",
          "amount_cents" => 1
        },
        open_operation(%{
          "operation_id" => "duplicate-rooms",
          "group_id" => "invalid-rooms",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 1},
            %{"room_id" => "same", "nightly_rate_cents" => 1}
          ]
        })
      ])
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "rounding-group",
               "deposit_due_cents" => 2,
               "revision" => 1
             },
             %{
               "operation_id" => "missing-date",
               "status" => "rejected",
               "code" => "invalid_operation",
               "group_id" => "rounding-group"
             },
             %{"operation_id" => 123, "status" => "rejected", "code" => "invalid_operation"},
             %{
               "operation_id" => "duplicate-rooms",
               "status" => "rejected",
               "code" => "invalid_rooms"
             }
           ]

    group = get(build_conn(), "/api/v1/groups/rounding-group") |> json_response(200)
    assert group["data"]["lodging_total_cents"] == 6
    assert group["data"]["deposit_due_cents"] == 2
    assert group["data"]["revision"] == 1
  end

  test "retains flexible payments cancelled fewer than fourteen days before arrival", %{
    conn: conn
  } do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "payment-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 5_000
        },
        %{
          "operation_id" => "late-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81"
        },
        %{
          "operation_id" => "after-cancel",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-28",
          "group_id" => "group-81",
          "amount_cents" => 1
        }
      ])
      |> json_response(200)

    assert response["results"] |> Enum.at(2) == %{
             "operation_id" => "late-cancel",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 0,
             "retained_cents" => 5_000,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert response["results"] |> Enum.at(3) == %{
             "operation_id" => "after-cancel",
             "status" => "rejected",
             "code" => "group_not_active",
             "group_id" => "group-81"
           }
  end

  test "returns documented errors for invalid batches and missing groups", %{conn: conn} do
    assert post(conn, "/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert get(build_conn(), "/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == %{
             "data" => ledger_data(%{})
           }
  end
end
