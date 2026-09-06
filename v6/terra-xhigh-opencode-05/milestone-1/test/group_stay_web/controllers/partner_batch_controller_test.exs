defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "opens a group and returns its calculated totals and rooms", %{conn: conn} do
    conn = post_batch(conn, [open_group("open-1")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/groups/group-1")

    assert %{
             "data" => %{
               "group_id" => "group-1",
               "guest_id" => "guest-1",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = json_response(conn, 200)
  end

  test "processes dependent operations in order and increments revisions", %{conn: conn} do
    operations = [
      open_group("open-1"),
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-1",
        "new_arrival_on" => "2026-12-15",
        "expected_revision" => 2
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "payment-1",
                 "status" => "applied",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "move-1",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-15",
                 "new_departure_on" => "2026-12-18",
                 "revision" => 3
               }
             ]
           } = post_batch(conn, operations) |> json_response(200)

    conn = get(build_conn(), "/api/v1/groups/group-1")

    assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 18_500}} =
             json_response(conn, 200)
  end

  test "rejects stale revisions before other domain validation without changing the group", %{
    conn: conn
  } do
    post_batch(conn, [open_group("open-1")])

    stale_payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "not-a-date",
      "group_id" => "group-1",
      "amount_cents" => -10,
      "expected_revision" => 0
    }

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-1",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } = post_batch(build_conn(), [stale_payment]) |> json_response(200)

    conn = get(build_conn(), "/api/v1/groups/group-1")
    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = json_response(conn, 200)
  end

  test "settles cancellation cash and reports ledger totals", %{conn: conn} do
    operations = [
      open_group("open-1"),
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-1"
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "cancel-1",
                 "status" => "applied",
                 "refunded_cents" => 1_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ]
           } = post_batch(conn, operations) |> json_response(200)

    conn = get(build_conn(), "/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 1_000,
               "cash_retained_cents" => 0
             }
           } = json_response(conn, 200)

    assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    cancelled_payment = %{
      "operation_id" => "payment-2",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-27",
      "group_id" => "group-1",
      "amount_cents" => 1
    }

    assert %{"results" => [%{"status" => "rejected", "code" => "group_not_active"}]} =
             post_batch(build_conn(), [cancelled_payment]) |> json_response(200)
  end

  test "retains advance-purchase cash on cancellation", %{conn: conn} do
    open_group = Map.put(open_group("open-1"), "rate_plan", "advance_purchase")

    payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 1_000
    }

    cancellation = %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1"
    }

    assert %{
             "results" => [
               %{"deposit_due_cents" => 97_500},
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 1_000}
             ]
           } = post_batch(conn, [open_group, payment, cancellation]) |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 0, "cash_retained_cents" => 1_000}} =
             get(build_conn(), "/api/v1/ledger") |> json_response(200)
  end

  test "keeps earlier operations when an operation is invalid and continues the batch", %{
    conn: conn
  } do
    operations = [
      open_group("open-1"),
      %{"operation_id" => "bad-1", "type" => "unknown"},
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 500
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{
                 "operation_id" => "bad-1",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"status" => "applied", "outstanding_deposit_cents" => 19_000}
             ]
           } = post_batch(conn, operations) |> json_response(200)
  end

  test "rejects invalid batches and missing groups with the documented response codes", %{
    conn: conn
  } do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             post(conn, "/api/v1/partner-batches", %{}) |> json_response(422)

    missing_group_payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "not-here",
      "amount_cents" => 500
    }

    assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
             post_batch(build_conn(), [missing_group_payment]) |> json_response(200)

    assert %{"error" => %{"code" => "group_not_found"}} =
             get(build_conn(), "/api/v1/groups/not-here") |> json_response(404)
  end

  test "rejects invalid opening data without creating a group", %{conn: conn} do
    invalid_rooms =
      open_group("open-1")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
      ])

    invalid_stay = open_group("open-2") |> Map.put("departure_on", "2026-12-10")
    invalid_rate_plan = open_group("open-3") |> Map.put("rate_plan", "corporate")

    assert %{
             "results" => [
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rate_plan"}
             ]
           } =
             post_batch(conn, [invalid_rooms, invalid_stay, invalid_rate_plan])
             |> json_response(200)

    assert %{"error" => %{"code" => "group_not_found"}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(404)
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp open_group(operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end
end
