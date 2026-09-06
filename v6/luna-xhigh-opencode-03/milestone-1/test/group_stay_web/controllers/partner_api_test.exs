defmodule GroupStayWeb.PartnerApiTest do
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
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "opens and reads a group with per-room deposit calculations", %{conn: conn} do
    response = submit(conn, [open_operation()])

    assert json_response(response, 200) == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           }

    response = get(conn, "/api/v1/groups/group-81")

    assert json_response(response, 200) == %{
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
  end

  test "processes ordered operations and settles the ledger on cancellation", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-12",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "expected_revision" => 3
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    assert Enum.at(results, 1)["outstanding_deposit_cents"] == 14_500
    assert Enum.at(results, 2)["new_departure_on"] == "2026-12-15"
    assert Enum.at(results, 3)["refunded_cents"] == 5_000
    assert Enum.at(results, 3)["retained_cents"] == 0

    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           }

    assert get(conn, "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "status"]) == "cancelled"
  end

  test "rejections do not stop the batch or increment the revision", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "bad-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "amount_cents" => 0
      },
      %{
        "operation_id" => "good-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      }
    ]

    assert %{"results" => [_, rejected, applied]} = json_response(submit(conn, operations), 200)

    assert rejected == %{
             "operation_id" => "bad-payment",
             "status" => "rejected",
             "code" => "invalid_amount"
           }

    assert applied["revision"] == 2
  end

  test "checks stale revisions before operation validation", %{conn: conn} do
    assert json_response(submit(conn, [open_operation()]), 200)

    stale_operation = %{
      "operation_id" => "stale-payment",
      "type" => "record_cash_payment",
      "group_id" => "group-81",
      "amount_cents" => 0,
      "expected_revision" => 0
    }

    assert json_response(submit(conn, [stale_operation]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           }
  end

  test "handles cancellation rules and invalid batches", %{conn: conn} do
    assert json_response(submit(conn, []), 200) == %{"results" => []}

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", Jason.encode!(%{}))
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}

    assert json_response(
             submit(conn, [
               open_operation(%{"rate_plan" => "advance_purchase"}),
               %{
                 "operation_id" => "payment-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "group-81"
               },
               %{
                 "operation_id" => "payment-2",
                 "type" => "record_cash_payment",
                 "group_id" => "group-81",
                 "amount_cents" => 1
               }
             ]),
             200
           )
           |> get_in(["results", Access.at(2)]) == %{
             "operation_id" => "cancel-1",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 0,
             "retained_cents" => 1_000,
             "revision" => 3
           }

    assert get(conn, "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "outstanding_deposit_cents"]) == 0
  end

  test "rejects missing groups and preserves room order", %{conn: conn} do
    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "missing-payment",
                 "type" => "record_cash_payment",
                 "group_id" => "missing",
                 "amount_cents" => 1
               },
               open_operation(%{
                 "rooms" => [
                   %{"room_id" => "second", "nightly_rate_cents" => 2},
                   %{"room_id" => "first", "nightly_rate_cents" => 1}
                 ]
               })
             ]),
             200
           )
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "missing-payment",
             "status" => "rejected",
             "code" => "group_not_found"
           }

    assert get(conn, "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{"room_id" => "second", "nightly_rate_cents" => 2},
             %{"room_id" => "first", "nightly_rate_cents" => 1}
           ]
  end

  test "rounds flexible deposits per room", %{conn: conn} do
    operation =
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "one", "nightly_rate_cents" => 1},
          %{"room_id" => "two", "nightly_rate_cents" => 2}
        ]
      })

    assert get_in(json_response(submit(conn, [operation]), 200), [
             "results",
             Access.at(0),
             "deposit_due_cents"
           ]) == 0
  end
end
