defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: true

  test "fixes each group's cancellation policy when it opens and recalculates its cutoff on reschedule",
       %{
         conn: conn
       } do
    conn =
      post_operations(conn, [
        open_operation("legacy-policy", %{"occurred_on" => "2026-12-31"}),
        open_operation("modern-policy"),
        open_operation("advance-policy", %{"rate_plan" => "advance_purchase"})
      ])

    assert %{
             "results" => [
               %{"group_id" => "legacy-policy", "revision" => 1},
               %{"group_id" => "modern-policy", "revision" => 1},
               %{"group_id" => "advance-policy", "revision" => 1}
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/legacy-policy")

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-15"
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/modern-policy")

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-01-30"
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/advance-policy")

    assert %{
             "data" => %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "move-legacy",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-10",
          "group_id" => "legacy-policy",
          "new_arrival_on" => "2027-04-15",
          "expected_revision" => 1
        },
        payment_operation("legacy-payment", "legacy-policy", 5_000, "2027-01-11", 2),
        %{
          "operation_id" => "cancel-on-legacy-cutoff",
          "type" => "cancel_group",
          "occurred_on" => "2027-04-01",
          "group_id" => "legacy-policy",
          "expected_revision" => 3
        }
      ])

    assert %{
             "results" => [
               %{
                 "new_arrival_on" => "2027-04-15",
                 "new_departure_on" => "2027-04-18",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-04-01",
                 "revision" => 2
               },
               %{"revision" => 3},
               %{
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ]
           } = json_response(conn, 200)
  end

  test "converts refundable cash to expiring hotel credit and reports the credit ledger", %{
    conn: conn
  } do
    conn = post_operations(conn, [open_operation("cash-to-credit")])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("cash-to-credit-payment", "cash-to-credit", 5, "2027-01-02", 1),
        %{
          "operation_id" => "cash-to-credit-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-30",
          "group_id" => "cash-to-credit",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 6,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-01-30")

    assert %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cash-to-credit-cancel",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-01-30"
                 }
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2027-01-30")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }
           } = json_response(conn, 200)
  end

  test "restores refundable applied credit, then removes it after its original expiry", %{
    conn: conn
  } do
    conn = issue_credit(conn, "restore-source", "restore-source-cancel", 5_000)

    conn =
      post_operations(conn, [
        open_operation("credit-funded", %{
          "arrival_on" => "2027-03-20",
          "departure_on" => "2027-03-23"
        })
      ])

    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-02-01",
          "group_id" => "credit-funded",
          "amount_cents" => 3_000,
          "expected_revision" => 1
        }
      ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "credit-funded",
                 "amount_cents" => 3_000,
                 "outstanding_deposit_cents" => 16_500,
                 "revision" => 2
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/credit-funded")

    assert %{
             "data" => %{
               "deposit_paid_cents" => 3_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 3_000
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2027-02-01")
    assert %{"data" => %{"credit_liability_cents" => 5_500}} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "cancel-credit-funded",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-18",
          "group_id" => "credit-funded",
          "expected_revision" => 2
        }
      ])

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

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-02-18")
    assert %{"data" => %{"available_cents" => 5_500}} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2028-01-31")
    assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2028-01-31")
    assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
  end

  test "consumes credit by expiry and source, without advancing revisions on rejected applications",
       %{
         conn: conn
       } do
    conn = issue_credit(conn, "tie-a", "a-cancel", 1_000)
    conn = issue_credit(conn, "tie-z", "z-cancel", 1_000)
    conn = post_operations(conn, [open_operation("credit-target")])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-01-30")

    assert %{
             "data" => %{
               "lots" => [
                 %{"source_operation_id" => "a-cancel", "remaining_cents" => 1_100},
                 %{"source_operation_id" => "z-cancel", "remaining_cents" => 1_100}
               ]
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "consume-first-lot",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-31",
          "group_id" => "credit-target",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "insufficient-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-31",
          "group_id" => "credit-target",
          "amount_cents" => 1_201,
          "expected_revision" => 2
        },
        %{
          "operation_id" => "too-much-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-31",
          "group_id" => "credit-target",
          "amount_cents" => 20_000,
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 2},
               %{"status" => "rejected", "code" => "insufficient_credit"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-01-31")

    assert %{
             "data" => %{
               "available_cents" => 1_200,
               "lots" => [
                 %{"source_operation_id" => "a-cancel", "remaining_cents" => 100},
                 %{"source_operation_id" => "z-cancel", "remaining_cents" => 1_100}
               ]
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "consume-same-lots-again",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-31",
          "group_id" => "credit-target",
          "amount_cents" => 200,
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-01-31")

    assert %{
             "data" => %{
               "available_cents" => 1_000,
               "lots" => [%{"source_operation_id" => "z-cancel", "remaining_cents" => 1_000}]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/credit-target")
    assert %{"data" => %{"revision" => 3}} = json_response(conn, 200)
  end

  test "consumes applied credit when a non-refundable group is cancelled", %{conn: conn} do
    conn = issue_credit(conn, "nonref-credit-source", "nonref-credit-source-cancel", 5_000)

    conn =
      post_operations(conn, [
        open_operation("nonref-credit-target", %{"rate_plan" => "advance_purchase"})
      ])

    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "apply-nonref-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-02-01",
          "group_id" => "nonref-credit-target",
          "amount_cents" => 3_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "cancel-nonref-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-02",
          "group_id" => "nonref-credit-target",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-02-02")
    assert %{"data" => %{"available_cents" => 2_500}} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2027-02-02")
    assert %{"data" => %{"credit_liability_cents" => 2_500}} = json_response(conn, 200)
  end

  test "rejects hotel credit on non-refundable groups after checking revisions", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation("advance-credit", %{"rate_plan" => "advance_purchase"})
      ])

    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("advance-payment", "advance-credit", 100, "2027-01-02", 1)
      ])

    assert %{"results" => [%{"revision" => 2}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "stale-credit-refund",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "advance-credit",
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        },
        %{
          "operation_id" => "unavailable-credit-refund",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "advance-credit",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2},
               %{"status" => "rejected", "code" => "refund_method_not_available"}
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/advance-credit")

    assert %{"data" => %{"status" => "active", "revision" => 2, "cash_paid_cents" => 100}} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=not-a-date")
    assert %{"error" => %{"code" => "invalid_date"}} = json_response(conn, 422)
  end

  defp issue_credit(conn, group_id, cancellation_operation_id, amount_cents) do
    conn = post_operations(conn, [open_operation(group_id)])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("#{group_id}-payment", group_id, amount_cents, "2027-01-02", 1),
        %{
          "operation_id" => cancellation_operation_id,
          "type" => "cancel_group",
          "occurred_on" => "2027-01-30",
          "group_id" => group_id,
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"revision" => 2}, %{"status" => "applied", "revision" => 3}]} =
             json_response(conn, 200)

    conn
  end

  defp post_operations(conn, operations) do
    post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp open_operation(group_id, overrides \\ %{}) do
    operation = %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-04",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }

    Map.merge(operation, overrides)
  end

  defp payment_operation(operation_id, group_id, amount_cents, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end
end
