defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Bookings.CreditLot
  alias GroupStay.Repo

  test "fixes the cancellation policy at booking and recomputes its date on reschedule", %{
    conn: conn
  } do
    operations = [
      open_operation("old-flex", "guest-policy", %{
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      open_operation("new-flex", "guest-policy", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      open_operation("advance", "guest-policy", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "advance_purchase"
      }),
      operation("move-old", "reschedule_group", "2027-01-02", %{
        "group_id" => "old-flex",
        "new_arrival_on" => "2027-04-01",
        "expected_revision" => 1
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.at(results, 3) == %{
             "operation_id" => "move-old",
             "status" => "applied",
             "group_id" => "old-flex",
             "new_arrival_on" => "2027-04-01",
             "new_departure_on" => "2027-04-02",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-03-18",
             "revision" => 2
           }

    assert_group_policy("old-flex", "flex-14", "2027-03-18")
    assert_group_policy("new-flex", "flex-30", "2027-01-30")
    assert_group_policy("advance", "advance-nonrefundable", nil)
  end

  test "the flex-30 boundary is inclusive and hotel credit cannot bypass a late cancellation", %{
    conn: conn
  } do
    operations = [
      open_operation("on-boundary", "boundary-guest", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-02",
        "departure_on" => "2027-03-03"
      }),
      operation("pay-boundary", "record_cash_payment", "2027-01-02", %{
        "group_id" => "on-boundary",
        "amount_cents" => 100
      }),
      operation("cancel-boundary", "cancel_group", "2027-01-31", %{
        "group_id" => "on-boundary",
        "refund_method" => "hotel_credit"
      }),
      open_operation("one-day-late", "boundary-guest", %{
        "operation_id" => "open-late",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-02",
        "departure_on" => "2027-03-03"
      }),
      operation("pay-late", "record_cash_payment", "2027-01-02", %{
        "group_id" => "one-day-late",
        "amount_cents" => 100
      }),
      operation("cancel-late", "cancel_group", "2027-02-01", %{
        "group_id" => "one-day-late",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.at(results, 2)["credit_issued_cents"] == 110
    assert Enum.at(results, 2)["status"] == "applied"
    assert Enum.at(results, 5)["code"] == "refund_method_not_available"

    conn = get(build_conn(), ~p"/api/v1/groups/one-day-late")
    assert %{"data" => %{"status" => "active", "revision" => 2}} = json_response(conn, 200)
  end

  test "converts refundable cash with a rounded bonus and restores applied credit without a second bonus",
       %{conn: conn} do
    operations = [
      open_operation("source", "guest-credit", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      operation("pay-source", "record_cash_payment", "2027-01-02", %{
        "group_id" => "source",
        "amount_cents" => 5_005
      }),
      operation("convert-source", "cancel_group", "2027-01-10", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open_operation("target", "guest-credit", %{
        "operation_id" => "open-target",
        "occurred_on" => "2027-01-11",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02"
      }),
      operation("use-credit", "apply_hotel_credit", "2027-01-11", %{
        "group_id" => "target",
        "amount_cents" => 3_000,
        "expected_revision" => 1
      }),
      operation("pay-target", "record_cash_payment", "2027-01-12", %{
        "group_id" => "target",
        "amount_cents" => 5,
        "expected_revision" => 2
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.at(results, 2) == %{
             "operation_id" => "convert-source",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 5_506,
             "revision" => 3
           }

    conn = get(build_conn(), ~p"/api/v1/guests/guest-credit/credit?on=2027-01-11")

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-credit",
               "available_cents" => 2_506,
               "lots" => [
                 %{
                   "source_operation_id" => "convert-source",
                   "remaining_cents" => 2_506,
                   "expires_on" => "2028-01-10"
                 }
               ]
             }
           }

    conn = get(build_conn(), ~p"/api/v1/groups/target")

    assert %{
             "data" => %{
               "deposit_paid_cents" => 3_005,
               "cash_paid_cents" => 5,
               "credit_paid_cents" => 3_000,
               "revision" => 3
             }
           } = json_response(conn, 200)

    assert_ledger("2027-01-11", %{
      "cash_held_cents" => 5,
      "cash_converted_to_credit_cents" => 5_005,
      "credit_liability_cents" => 5_506
    })

    assert_ledger("2028-01-11", %{"credit_liability_cents" => 3_000})

    cancel =
      operation("convert-target", "cancel_group", "2027-02-01", %{
        "group_id" => "target",
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      })

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [cancel]})

    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["credit_issued_cents"] == 6
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0

    conn = get(build_conn(), ~p"/api/v1/guests/guest-credit/credit?on=2027-02-01")
    assert %{"data" => %{"available_cents" => 5_512, "lots" => lots}} = json_response(conn, 200)
    assert Enum.map(lots, & &1["remaining_cents"]) == [5_506, 6]

    assert_ledger("2027-02-01", %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 5_010,
      "credit_liability_cents" => 5_512
    })
  end

  test "uses credit by expiry then source operation and leaves liability unchanged", %{conn: conn} do
    insert_lot("ordering-guest", "z-early", 50, ~D[2027-05-01])
    insert_lot("ordering-guest", "z-later", 100, ~D[2027-06-01])
    insert_lot("ordering-guest", "a-later", 100, ~D[2027-06-01])

    operations = [
      open_operation("ordering-target", "ordering-guest", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-08-01",
        "departure_on" => "2027-08-02"
      }),
      operation("apply-ordered", "apply_hotel_credit", "2027-02-01", %{
        "group_id" => "ordering-target",
        "amount_cents" => 120
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/ordering-guest/credit?on=2027-02-01")

    assert %{"data" => %{"available_cents" => 130, "lots" => lots}} = json_response(conn, 200)

    assert lots == [
             %{
               "source_operation_id" => "a-later",
               "remaining_cents" => 30,
               "expires_on" => "2027-06-01"
             },
             %{
               "source_operation_id" => "z-later",
               "remaining_cents" => 100,
               "expires_on" => "2027-06-01"
             }
           ]

    assert_ledger("2027-02-01", %{"credit_liability_cents" => 250})
  end

  test "an expired restored lot immediately leaves the liability", %{conn: conn} do
    insert_lot("expiry-guest", "short-lived", 1_000, ~D[2027-01-10])

    operations = [
      open_operation("expiry-target", "expiry-guest", %{
        "occurred_on" => "2027-01-02",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16"
      }),
      operation("apply-short-lived", "apply_hotel_credit", "2027-01-05", %{
        "group_id" => "expiry-target",
        "amount_cents" => 1_000
      }),
      operation("cancel-after-expiry", "cancel_group", "2027-02-01", %{
        "group_id" => "expiry-target"
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    conn = get(build_conn(), ~p"/api/v1/guests/expiry-guest/credit?on=2027-02-01")

    assert json_response(conn, 200)["data"] == %{
             "guest_id" => "expiry-guest",
             "available_cents" => 0,
             "lots" => []
           }

    assert_ledger("2027-02-01", %{"credit_liability_cents" => 0})
  end

  test "rejections preserve revision and non-refundable cancellation consumes applied credit", %{
    conn: conn
  } do
    insert_lot("advance-guest", "advance-credit", 1_000, ~D[2028-01-01])

    operations = [
      open_operation("advance-target", "advance-guest", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "advance_purchase"
      }),
      operation("insufficient", "apply_hotel_credit", "2027-01-02", %{
        "group_id" => "advance-target",
        "amount_cents" => 1_001,
        "expected_revision" => 1
      }),
      operation("apply", "apply_hotel_credit", "2027-01-02", %{
        "group_id" => "advance-target",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      }),
      operation("stale-method", "cancel_group", "2027-01-03", %{
        "group_id" => "advance-target",
        "refund_method" => "hotel_credit",
        "expected_revision" => 1
      }),
      operation("unavailable-method", "cancel_group", "2027-01-03", %{
        "group_id" => "advance-target",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }),
      operation("cancel", "cancel_group", "2027-01-03", %{
        "group_id" => "advance-target",
        "expected_revision" => 2
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.map(results, & &1["code"]) == [
             nil,
             "insufficient_credit",
             nil,
             "stale_revision",
             "refund_method_not_available",
             nil
           ]

    assert Enum.at(results, 3)["actual_revision"] == 2
    assert Enum.at(results, 5)["revision"] == 3
    assert Enum.at(results, 5)["retained_cents"] == 0
    assert_ledger("2027-01-03", %{"credit_liability_cents" => 0})
  end

  defp assert_group_policy(group_id, policy_version, refundable_until) do
    conn = get(build_conn(), "/api/v1/groups/#{group_id}")

    assert %{
             "data" => %{
               "policy_version" => ^policy_version,
               "refundable_until" => ^refundable_until
             }
           } = json_response(conn, 200)
  end

  defp assert_ledger(on, expected) do
    conn = get(build_conn(), "/api/v1/ledger?on=#{on}")
    assert %{"data" => data} = json_response(conn, 200)

    Enum.each(expected, fn {key, value} -> assert data[key] == value end)
  end

  defp insert_lot(guest_id, source_operation_id, remaining_cents, expires_on) do
    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: remaining_cents,
      issued_on: ~D[2027-01-01],
      expires_on: expires_on
    })
  end

  defp open_operation(group_id, guest_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 50_000}]
      },
      overrides
    )
  end

  defp operation(operation_id, type, occurred_on, fields) do
    Map.merge(
      %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on},
      fields
    )
  end
end
