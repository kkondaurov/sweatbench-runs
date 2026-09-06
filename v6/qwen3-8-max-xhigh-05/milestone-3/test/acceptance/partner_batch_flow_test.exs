defmodule GroupStay.Acceptance.PartnerBatchFlowTest do
  use GroupStayWeb.ConnCase

  test "processes a mixed batch in order, with later operations seeing earlier results", %{
    conn: conn
  } do
    operations = [
      %{
        "operation_id" => "op-1001",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9500,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "op-3001",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-17",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "op-2002",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "amount_cents" => 10000,
        "expected_revision" => 2
      },
      %{
        "operation_id" => "op-2003",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "amount_cents" => 10000,
        "expected_revision" => 3
      },
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-03",
        "group_id" => "group-81",
        "expected_revision" => 4
      }
    ]

    %{"results" => results} = submit_batch(conn, operations)

    assert [
             %{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19500},
             %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 10000},
             %{
               "status" => "applied",
               "revision" => 3,
               "new_arrival_on" => "2026-12-17",
               "new_departure_on" => "2026-12-20"
             },
             %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 3},
             %{"status" => "applied", "revision" => 4, "outstanding_deposit_cents" => 0},
             %{
               "status" => "applied",
               "revision" => 5,
               "refunded_cents" => 19500,
               "retained_cents" => 0
             }
           ] = results

    data = group_data(conn, "group-81")
    assert data["status"] == "cancelled"
    assert data["arrival_on"] == "2026-12-17"
    assert data["revision"] == 5

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 19500,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "credit issued earlier in a batch is usable later in the same batch", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "op-1001",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "op-1002",
        "type" => "open_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-82",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-02-10",
        "departure_on" => "2027-02-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      %{
        "operation_id" => "op-6001",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-82",
        "amount_cents" => 5500
      }
    ]

    %{"results" => results} = submit_batch(conn, operations)

    assert [
             %{"status" => "applied", "revision" => 1},
             %{"status" => "applied", "revision" => 2},
             %{
               "status" => "applied",
               "revision" => 3,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500
             },
             %{"status" => "applied", "revision" => 1},
             %{
               "status" => "applied",
               "revision" => 2,
               "amount_cents" => 5500,
               "outstanding_deposit_cents" => 14000
             }
           ] = results

    data = group_data(conn, "group-82")
    assert data["cash_paid_cents"] == 0
    assert data["credit_paid_cents"] == 5500
    assert data["outstanding_deposit_cents"] == 14000

    assert guest_credit_data(conn, "guest-22")["available_cents"] == 0
    assert ledger_data(conn)["credit_liability_cents"] == 5500
    assert ledger_data(conn)["cash_converted_to_credit_cents"] == 5000
  end

  test "a retried batch returns the same results with at-most-once effects", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "op-1001",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9500,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "op-2002",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "amount_cents" => 10000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "expected_revision" => 2
      }
    ]

    %{"results" => first_results} = submit_batch(conn, operations)

    assert Enum.map(first_results, & &1["status"]) ==
             ["applied", "applied", "rejected", "applied"]

    # The gateway lost the response and retries the whole batch.
    %{"results" => retry_results} = submit_batch(conn, operations)

    assert retry_results == first_results

    data = group_data(conn, "group-81")
    assert data["status"] == "cancelled"
    assert data["revision"] == 3
    assert data["deposit_paid_cents"] == 9500

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 9500,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "rejections do not undo earlier operations and do not stop later ones", %{conn: conn} do
    open_group_fixture(conn)

    operations = [
      %{
        "operation_id" => "op-bad",
        "type" => "unknown_type",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 19500
      }
    ]

    %{"results" => [rejected, applied]} = submit_batch(conn, operations)

    assert rejected["code"] == "invalid_operation"
    assert applied["status"] == "applied"

    assert group_data(conn, "group-81")["outstanding_deposit_cents"] == 0
  end

  test "applied operations increment the revision exactly once; rejections never do", %{
    conn: conn
  } do
    open_group_fixture(conn)

    operations = [
      %{
        "operation_id" => "op-a",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 0
      },
      %{
        "operation_id" => "op-b",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1000
      },
      %{
        "operation_id" => "op-c",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-17",
        "expected_revision" => 1
      },
      %{
        "operation_id" => "op-d",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-17",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "op-e",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }
    ]

    %{"results" => results} = submit_batch(conn, operations)

    assert Enum.map(results, &{&1["status"], &1["code"]}) == [
             {"rejected", "invalid_amount"},
             {"applied", nil},
             {"rejected", "stale_revision"},
             {"applied", nil},
             {"applied", nil}
           ]

    assert group_data(conn, "group-81")["revision"] == 4
  end
end
