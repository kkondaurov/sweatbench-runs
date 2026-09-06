defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: true

  import Phoenix.ConnTest

  test "assigns a booking-date policy once and recomputes its refundable date when rescheduled",
       %{
         conn: conn
       } do
    legacy =
      open_group(%{
        "operation_id" => "open-legacy",
        "group_id" => "legacy",
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-02-15",
        "departure_on" => "2027-02-18"
      })

    new_policy =
      open_group(%{
        "operation_id" => "open-new-policy",
        "group_id" => "new-policy",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-18"
      })

    move = %{
      "operation_id" => "move-new-policy",
      "type" => "reschedule_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "new-policy",
      "new_arrival_on" => "2027-04-20"
    }

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "applied",
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-03-21",
                 "revision" => 2
               }
             ]
           } = post_operations(conn, [legacy, new_policy, move])

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-01"
             }
           } = get(build_conn(), "/api/v1/groups/legacy") |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "arrival_on" => "2027-04-20",
               "departure_on" => "2027-04-23",
               "refundable_until" => "2027-03-21"
             }
           } = get(build_conn(), "/api/v1/groups/new-policy") |> json_response(200)
  end

  test "converts refundable cash to expiring credit and reports the new ledger totals", %{
    conn: conn
  } do
    group =
      open_group(%{
        "operation_id" => "open-credit-source",
        "group_id" => "credit-source",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-13"
      })

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "cancel-to-credit",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 1_100,
                 "revision" => 3
               }
             ]
           } =
             post_operations(conn, [
               group,
               cash_payment("pay-credit-source", "credit-source", "2027-01-02", 1_000),
               cancellation("cancel-to-credit", "credit-source", "2027-02-01", "hotel_credit")
             ])

    assert %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 1_100,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-to-credit",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-02-02"
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-02-01")
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_000,
               "credit_liability_cents" => 1_100
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-02-01") |> json_response(200)

    assert %{"data" => %{"cash_paid_cents" => 0, "credit_paid_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/credit-source") |> json_response(200)
  end

  test "uses credit lots in expiry order and restores refundable credit to its original lots", %{
    conn: conn
  } do
    first_source = source_group("first-source", "open-first", "2027-01-01", "2027-04-10")
    second_source = source_group("second-source", "open-second", "2027-01-03", "2027-04-12")

    target =
      open_group(%{
        "operation_id" => "open-credit-target",
        "group_id" => "credit-target",
        "occurred_on" => "2027-02-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "apply-credit",
                 "status" => "applied",
                 "amount_cents" => 1_500,
                 "outstanding_deposit_cents" => 18_000,
                 "revision" => 2
               },
               %{
                 "operation_id" => "cancel-credit-target",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             post_operations(conn, [
               first_source,
               second_source,
               cash_payment("pay-first", "first-source", "2027-01-02", 1_000),
               cash_payment("pay-second", "second-source", "2027-01-04", 1_000),
               cancellation("cancel-first", "first-source", "2027-02-01", "hotel_credit"),
               cancellation("cancel-second", "second-source", "2027-02-01", "hotel_credit"),
               target,
               hotel_credit("apply-credit", "credit-target", "2027-02-02", 1_500),
               cancellation("cancel-credit-target", "credit-target", "2027-03-01", "cash")
             ])

    assert %{
             "data" => %{
               "available_cents" => 2_200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-first",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-02-02"
                 },
                 %{
                   "source_operation_id" => "cancel-second",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-02-02"
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-03-01")
             |> json_response(200)

    assert %{
             "data" => %{
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           } = get(build_conn(), "/api/v1/groups/credit-target") |> json_response(200)
  end

  test "pauses an applied lot's expiry but drops it when refundable cancellation restores it too late",
       %{conn: conn} do
    source =
      open_group(%{
        "operation_id" => "open-expiring-source",
        "group_id" => "expiring-source",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-05-01",
        "departure_on" => "2027-05-04"
      })

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ]
           } =
             post_operations(conn, [
               source,
               cash_payment("pay-expiring-source", "expiring-source", "2027-01-02", 1_000),
               cancellation(
                 "cancel-expiring-source",
                 "expiring-source",
                 "2027-02-01",
                 "hotel_credit"
               )
             ])

    target =
      open_group(%{
        "operation_id" => "open-expiring-target",
        "group_id" => "expiring-target",
        "occurred_on" => "2027-03-01",
        "arrival_on" => "2028-04-05",
        "departure_on" => "2028-04-08"
      })

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2}
             ]
           } =
             post_operations(build_conn(), [
               target,
               hotel_credit("apply-expiring-credit", "expiring-target", "2027-03-02", 1_100)
             ])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2028-02-03")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 1_100}} =
             get(build_conn(), "/api/v1/ledger?on=2028-02-03") |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             post_operations(build_conn(), [
               cancellation("cancel-expiring-target", "expiring-target", "2028-03-01", "cash")
             ])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2028-03-01")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(build_conn(), "/api/v1/ledger?on=2028-03-01") |> json_response(200)
  end

  test "rejects unavailable credit methods and insufficient credit without advancing the revision",
       %{
         conn: conn
       } do
    advance =
      open_group(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-13"
      })

    empty_credit =
      open_group(%{
        "operation_id" => "open-empty-credit",
        "group_id" => "empty-credit",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-13"
      })

    unavailable_method =
      cancellation("no-credit-for-advance", "advance", "2027-01-02", "hotel_credit")

    insufficient = hotel_credit("insufficient", "empty-credit", "2027-01-02", 1)

    stale_unavailable =
      Map.merge(unavailable_method, %{
        "operation_id" => "stale-before-method",
        "expected_revision" => 0
      })

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "no-credit-for-advance",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               },
               %{
                 "operation_id" => "insufficient",
                 "status" => "rejected",
                 "code" => "insufficient_credit"
               },
               %{
                 "operation_id" => "stale-before-method",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } =
             post_operations(conn, [
               advance,
               empty_credit,
               unavailable_method,
               insufficient,
               stale_unavailable
             ])

    assert %{"data" => %{"status" => "active", "revision" => 1}} =
             get(build_conn(), "/api/v1/groups/advance") |> json_response(200)

    assert %{"data" => %{"status" => "active", "revision" => 1}} =
             get(build_conn(), "/api/v1/groups/empty-credit") |> json_response(200)
  end

  defp source_group(group_id, operation_id, occurred_on, arrival_on) do
    open_group(%{
      "operation_id" => operation_id,
      "group_id" => group_id,
      "occurred_on" => occurred_on,
      "arrival_on" => arrival_on,
      "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 3) |> Date.to_iso8601()
    })
  end

  defp open_group(overrides) do
    Map.merge(
      %{
        "operation_id" => "open-group",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp hotel_credit(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancellation(operation_id, group_id, occurred_on, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
