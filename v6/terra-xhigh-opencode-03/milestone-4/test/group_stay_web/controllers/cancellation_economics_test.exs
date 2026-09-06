defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-03-01",
        "departure_on" => "2026-03-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 1_000}]
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

  test "fixes the cancellation policy at booking and recomputes its date on reschedule", %{
    conn: conn
  } do
    response =
      conn
      |> submit([
        open_operation("flex-14", %{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        open_operation("flex-30", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        open_operation("advance", %{
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2027-01-01"
        }),
        %{
          "operation_id" => "move-flex-30",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "flex-30",
          "new_arrival_on" => "2027-04-01"
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 3) == %{
             "operation_id" => "move-flex-30",
             "status" => "applied",
             "group_id" => "flex-30",
             "new_arrival_on" => "2027-04-01",
             "new_departure_on" => "2027-04-02",
             "policy_version" => "flex-30",
             "refundable_until" => "2027-03-02",
             "revision" => 2
           }

    assert get(build_conn(), "/api/v1/groups/flex-14") |> json_response(200) == %{
             "data" => %{
               "group_id" => "flex-14",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-12-31",
               "arrival_on" => "2027-03-01",
               "departure_on" => "2027-03-02",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-15",
               "status" => "active",
               "revision" => 1,
               "rooms" => [room("room-flex-14", 1_000, 1_000, 200)],
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 200
             }
           }

    assert get(build_conn(), "/api/v1/groups/advance") |> json_response(200) == %{
             "data" => %{
               "group_id" => "advance",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2027-01-01",
               "arrival_on" => "2026-03-01",
               "departure_on" => "2026-03-02",
               "rate_plan" => "advance_purchase",
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil,
               "status" => "active",
               "revision" => 1,
               "rooms" => [room("room-advance", 1_000, 1_000, 1_000)],
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 1_000,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 1_000
             }
           }
  end

  test "issues refundable hotel credit with its bonus and reports expiry-aware totals", %{
    conn: conn
  } do
    response =
      conn
      |> submit([
        open_operation("credit-source", %{
          "arrival_on" => "2026-03-01",
          "departure_on" => "2026-03-02"
        }),
        %{
          "operation_id" => "cash-source",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "credit-source",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "credit-issue",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "credit-source",
          "refund_method" => "hotel_credit"
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "credit-issue",
             "status" => "applied",
             "group_id" => "credit-source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 110,
             "revision" => 3
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-01-03")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-issue",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-01-03"
                 }
               ]
             }
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-01-04")
           |> json_response(200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    assert get(build_conn(), "/api/v1/ledger?on=2026-01-03") |> json_response(200) == %{
             "data" =>
               ledger_data(%{
                 "cash_converted_to_credit_cents" => 100,
                 "credit_liability_cents" => 110
               })
           }
  end

  test "consumes credit by expiry and source, then restores it without another bonus", %{
    conn: conn
  } do
    response =
      conn
      |> submit([
        open_operation("source-a"),
        %{
          "operation_id" => "cash-a",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "source-a",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "credit-a",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "source-a",
          "refund_method" => "hotel_credit"
        },
        open_operation("source-b"),
        %{
          "operation_id" => "cash-b",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => "source-b",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "credit-b",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "source-b",
          "refund_method" => "hotel_credit"
        },
        open_operation("credit-target"),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-01-04",
          "group_id" => "credit-target",
          "amount_cents" => 150
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 7) == %{
             "operation_id" => "apply-credit",
             "status" => "applied",
             "group_id" => "credit-target",
             "amount_cents" => 150,
             "outstanding_deposit_cents" => 50,
             "revision" => 2
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-01-04")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 70,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-b",
                   "remaining_cents" => 70,
                   "expires_on" => "2027-01-03"
                 }
               ]
             }
           }

    assert get(build_conn(), "/api/v1/groups/credit-target")
           |> json_response(200)
           |> get_in(["data"]) ==
             %{
               "group_id" => "credit-target",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-01-01",
               "arrival_on" => "2026-03-01",
               "departure_on" => "2026-03-02",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-02-15",
               "status" => "active",
               "revision" => 2,
               "rooms" => [room("room-credit-target", 1_000, 1_000, 200, 0, 150)],
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "deposit_paid_cents" => 150,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 150,
               "outstanding_deposit_cents" => 50
             }

    assert get(build_conn(), "/api/v1/ledger?on=2026-01-04") |> json_response(200) == %{
             "data" =>
               ledger_data(%{
                 "cash_converted_to_credit_cents" => 200,
                 "credit_liability_cents" => 220
               })
           }

    cancellation =
      build_conn()
      |> submit([
        %{
          "operation_id" => "cancel-credit-target",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-05",
          "group_id" => "credit-target"
        }
      ])
      |> json_response(200)

    assert cancellation["results"] == [
             %{
               "operation_id" => "cancel-credit-target",
               "status" => "applied",
               "group_id" => "credit-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ]

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-01-05")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 220,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-a",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-01-03"
                 },
                 %{
                   "source_operation_id" => "credit-b",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-01-03"
                 }
               ]
             }
           }
  end

  test "rejects unavailable credit refunds and expires restored credit after its original expiry",
       %{
         conn: conn
       } do
    response =
      conn
      |> submit([
        open_operation("expired-source"),
        %{
          "operation_id" => "expired-cash",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-01",
          "group_id" => "expired-source",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "expired-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-01",
          "group_id" => "expired-source",
          "refund_method" => "hotel_credit"
        },
        open_operation("expired-target", %{
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        %{
          "operation_id" => "apply-expiring-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-01-02",
          "group_id" => "expired-target",
          "amount_cents" => 110
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 4)["status"] == "applied"

    assert get(build_conn(), "/api/v1/ledger?on=2027-01-02") |> json_response(200) == %{
             "data" =>
               ledger_data(%{
                 "cash_converted_to_credit_cents" => 100,
                 "credit_liability_cents" => 110
               })
           }

    cancellation =
      build_conn()
      |> submit([
        %{
          "operation_id" => "cancel-expired-target",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "expired-target"
        },
        open_operation("late-flex", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        %{
          "operation_id" => "late-flex-cash",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-02",
          "group_id" => "late-flex",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "insufficient-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-02",
          "group_id" => "late-flex",
          "amount_cents" => 1,
          "expected_revision" => 2
        },
        %{
          "operation_id" => "unavailable-credit-refund",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-31",
          "group_id" => "late-flex",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])
      |> json_response(200)

    assert Enum.at(cancellation["results"], 0) == %{
             "operation_id" => "cancel-expired-target",
             "status" => "applied",
             "group_id" => "expired-target",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert Enum.at(cancellation["results"], 3) == %{
             "operation_id" => "insufficient-credit",
             "status" => "rejected",
             "code" => "insufficient_credit",
             "group_id" => "late-flex"
           }

    assert Enum.at(cancellation["results"], 4) == %{
             "operation_id" => "unavailable-credit-refund",
             "status" => "rejected",
             "code" => "refund_method_not_available",
             "group_id" => "late-flex"
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-01-02")
           |> json_response(200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    assert get(build_conn(), "/api/v1/groups/late-flex") |> json_response(200) |> get_in(["data"]) ==
             %{
               "group_id" => "late-flex",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2027-01-01",
               "arrival_on" => "2027-03-01",
               "departure_on" => "2027-03-02",
               "rate_plan" => "flexible",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-01-30",
               "status" => "active",
               "revision" => 2,
               "rooms" => [room("room-late-flex", 1_000, 1_000, 200, 100)],
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "deposit_paid_cents" => 100,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 100
             }
  end

  test "restores every allocation made from the same credit lot", %{conn: conn} do
    conn
    |> submit([
      open_operation("single-lot-source"),
      %{
        "operation_id" => "single-lot-cash",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "single-lot-source",
        "amount_cents" => 200
      },
      %{
        "operation_id" => "single-lot-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "single-lot-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("single-lot-target"),
      %{
        "operation_id" => "single-lot-apply-one",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "single-lot-target",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "single-lot-apply-two",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "single-lot-target",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "single-lot-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-05",
        "group_id" => "single-lot-target"
      }
    ])
    |> json_response(200)

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-01-05")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 220,
               "lots" => [
                 %{
                   "source_operation_id" => "single-lot-credit",
                   "remaining_cents" => 220,
                   "expires_on" => "2027-01-03"
                 }
               ]
             }
           }
  end
end
