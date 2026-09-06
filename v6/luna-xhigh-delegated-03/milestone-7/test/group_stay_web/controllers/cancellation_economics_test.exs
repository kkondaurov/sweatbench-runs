defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp open_operation(group_id, guest_id, operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp fund_credit(
         conn,
         group_id,
         guest_id,
         cash_cents,
         opened_on,
         cancelled_on,
         operation_prefix
       ) do
    operations = [
      open_operation(group_id, guest_id, "#{operation_prefix}-open", %{
        "occurred_on" => opened_on,
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      }),
      %{
        "operation_id" => "#{operation_prefix}-pay",
        "type" => "record_cash_payment",
        "occurred_on" => opened_on,
        "group_id" => group_id,
        "amount_cents" => cash_cents
      },
      %{
        "operation_id" => "#{operation_prefix}-cancel",
        "type" => "cancel_group",
        "occurred_on" => cancelled_on,
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3}
             ]
           } = post_batch(conn, operations) |> json_response(200)

    conn
  end

  test "fixes the policy at booking and recomputes only the date on reschedule", %{conn: conn} do
    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ]
           } =
             post_batch(conn, [
               open_operation("old", "guest-old", "open-old", %{
                 "occurred_on" => "2026-12-31",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-13"
               }),
               open_operation("new", "guest-new", "open-new"),
               open_operation("advance", "guest-advance", "open-advance", %{
                 "rate_plan" => "advance_purchase"
               })
             ])
             |> json_response(200)

    old = json_response(get(conn, "/api/v1/groups/old"), 200)["data"]
    assert old["policy_version"] == "flex-14"
    assert old["refundable_until"] == "2027-02-24"

    assert json_response(get(conn, "/api/v1/groups/new"), 200)["data"]["policy_version"] ==
             "flex-30"

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "revision" => 2,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-13",
                 "new_departure_on" => "2027-03-30"
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "move-old",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "old",
                 "new_arrival_on" => "2027-03-27",
                 "expected_revision" => 1
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/groups/old"), 200)["data"]["refundable_until"] ==
             "2027-03-13"

    advance = json_response(get(conn, "/api/v1/groups/advance"), 200)["data"]
    assert advance["policy_version"] == "advance-nonrefundable"
    assert advance["refundable_until"] == nil
  end

  test "converts refundable cash into expiring credit with the standard rounding", %{conn: conn} do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 1_101,
                 "revision" => 3
               }
             ]
           } =
             post_batch(conn, [
               open_operation("credit-source", "guest-22", "open-source", %{
                 "arrival_on" => "2027-04-10"
               }),
               %{
                 "operation_id" => "pay-source",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "credit-source",
                 "amount_cents" => 1_001
               },
               %{
                 "operation_id" => "cancel-source",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2028-01-02"), 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 1_101,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 1_101,
                   "expires_on" => "2028-01-03"
                 }
               ]
             }
           }

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2028-01-03"), 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    assert json_response(get(conn, "/api/v1/ledger?on=2028-01-02"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_001,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 1_101
           }

    assert json_response(get(conn, "/api/v1/ledger?on=2028-01-03"), 200)["data"][
             "credit_liability_cents"
           ] == 0
  end

  test "consumes credit by expiry and restores the original lots on refundable cancellation", %{
    conn: conn
  } do
    conn = fund_credit(conn, "source-a", "guest-lots", 1_000, "2027-01-01", "2027-01-01", "a")
    conn = fund_credit(conn, "source-b", "guest-lots", 2_000, "2027-02-01", "2027-02-01", "b")

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("target", "guest-lots", "target-open", %{
                 "occurred_on" => "2027-03-01",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               })
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "amount_cents" => 2_000,
                 "outstanding_deposit_cents" => 7_000,
                 "revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "apply-target",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-03-02",
                 "group_id" => "target",
                 "amount_cents" => 2_000,
                 "expected_revision" => 1
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/guests/guest-lots/credit?on=2027-03-03"), 200)["data"] ==
             %{
               "guest_id" => "guest-lots",
               "available_cents" => 1_300,
               "lots" => [
                 %{
                   "source_operation_id" => "b-cancel",
                   "remaining_cents" => 1_300,
                   "expires_on" => "2028-02-02"
                 }
               ]
             }

    target = json_response(get(conn, "/api/v1/groups/target"), 200)["data"]
    assert target["cash_paid_cents"] == 0
    assert target["credit_paid_cents"] == 2_000

    assert %{"results" => [%{"revision" => 3, "credit_issued_cents" => 0}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-03-03",
                 "group_id" => "target",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/guests/guest-lots/credit?on=2027-03-04"), 200)["data"] ==
             %{
               "guest_id" => "guest-lots",
               "available_cents" => 3_300,
               "lots" => [
                 %{
                   "source_operation_id" => "a-cancel",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-01-02"
                 },
                 %{
                   "source_operation_id" => "b-cancel",
                   "remaining_cents" => 2_200,
                   "expires_on" => "2028-02-02"
                 }
               ]
             }
  end

  test "expired credit restored from a refundable cancellation is no longer a liability", %{
    conn: conn
  } do
    conn =
      fund_credit(conn, "source", "guest-expired", 1_000, "2027-01-01", "2027-01-01", "source")

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("expired-target", "guest-expired", "target-open", %{
                 "occurred_on" => "2027-01-02",
                 "arrival_on" => "2028-02-20",
                 "departure_on" => "2028-02-23"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "apply-expired-target",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "expired-target",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 3, "refunded_cents" => 0}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-expired-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2028-01-02",
                 "group_id" => "expired-target"
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/guests/guest-expired/credit?on=2028-01-02"), 200)[
             "data"
           ] == %{
             "guest_id" => "guest-expired",
             "available_cents" => 0,
             "lots" => []
           }

    assert json_response(get(conn, "/api/v1/ledger?on=2028-01-02"), 200)["data"][
             "credit_liability_cents"
           ] == 0
  end

  test "does not offer credit for non-refundable cancellations and consumes applied credit", %{
    conn: conn
  } do
    conn =
      fund_credit(conn, "source", "guest-advance", 909, "2027-01-01", "2027-01-01", "source")

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("advance-target", "guest-advance", "advance-open", %{
                 "rate_plan" => "advance_purchase"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "apply-advance-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "advance-target",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert json_response(
             post_batch(conn, [
               %{
                 "operation_id" => "bad-advance-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "advance-target",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "bad-advance-cancel",
                 "status" => "rejected",
                 "code" => "refund_method_not_available",
                 "group_id" => "advance-target"
               }
             ]
           }

    assert %{"results" => [%{"revision" => 3, "retained_cents" => 0}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "advance-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "advance-target",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    group = json_response(get(conn, "/api/v1/groups/advance-target"), 200)["data"]
    assert group["cash_paid_cents"] == 0
    assert group["credit_paid_cents"] == 0

    assert json_response(get(conn, "/api/v1/ledger?on=2027-01-03"), 200)["data"][
             "credit_liability_cents"
           ] == 0
  end

  test "checks revisions before insufficient-credit validation", %{conn: conn} do
    conn = fund_credit(conn, "source", "guest-revisions", 5, "2027-01-01", "2027-01-01", "source")

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("revision-target", "guest-revisions", "target-open")
             ])
             |> json_response(200)

    assert json_response(
             post_batch(conn, [
               %{
                 "operation_id" => "stale-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "revision-target",
                 "amount_cents" => 10,
                 "expected_revision" => 99
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "stale-credit",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "revision-target",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ]
           }

    assert json_response(
             post_batch(conn, [
               %{
                 "operation_id" => "insufficient-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "revision-target",
                 "amount_cents" => 10,
                 "expected_revision" => 1
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "insufficient-credit",
                 "status" => "rejected",
                 "code" => "insufficient_credit",
                 "group_id" => "revision-target"
               }
             ]
           }

    assert json_response(get(conn, "/api/v1/groups/revision-target"), 200)["data"]["revision"] ==
             1
  end

  test "cancellation on the policy date is refundable but the next day is not", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("boundary", "guest-boundary", "boundary-open", %{
                 "arrival_on" => "2027-04-01",
                 "departure_on" => "2027-04-04"
               }),
               open_operation("late", "guest-late", "late-open", %{
                 "arrival_on" => "2027-04-01",
                 "departure_on" => "2027-04-04"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}, %{"revision" => 2}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "boundary-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "boundary",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "late-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "late",
                 "amount_cents" => 100
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"refunded_cents" => 100, "retained_cents" => 0, "revision" => 3}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "boundary-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-03-02",
                 "group_id" => "boundary"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"refunded_cents" => 0, "retained_cents" => 100, "revision" => 3}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "late-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-03-03",
                 "group_id" => "late"
               }
             ])
             |> json_response(200)
  end

  test "settles mixed cash and credit without rebating credit or losing funding history", %{
    conn: conn
  } do
    conn = fund_credit(conn, "source", "guest-mixed", 909, "2027-01-01", "2027-01-01", "source")

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("mixed", "guest-mixed", "mixed-open", %{
                 "occurred_on" => "2027-03-01",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "mixed-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-03-02",
                 "group_id" => "mixed",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "mixed-cash",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-03-02",
                 "group_id" => "mixed",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "revision" => 4,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 1_100
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "mixed-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-03-02",
                 "group_id" => "mixed",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)

    group = json_response(get(conn, "/api/v1/groups/mixed"), 200)["data"]
    assert group["cash_paid_cents"] == 0
    assert group["credit_paid_cents"] == 0

    assert json_response(get(conn, "/api/v1/guests/guest-mixed/credit?on=2027-03-03"), 200)[
             "data"
           ] == %{
             "guest_id" => "guest-mixed",
             "available_cents" => 2_100,
             "lots" => [
               %{
                 "source_operation_id" => "source-cancel",
                 "remaining_cents" => 1_000,
                 "expires_on" => "2028-01-02"
               },
               %{
                 "source_operation_id" => "mixed-cancel",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2028-03-02"
               }
             ]
           }

    assert json_response(get(conn, "/api/v1/ledger?on=2027-03-03"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_909,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 2_100
           }
  end
end
