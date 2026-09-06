defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-1",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 15000},
          %{room_id: "room-b", nightly_rate_cents: 17500}
        ]
      },
      overrides
    )
  end

  test "opens a group, calculates its deposit, and preserves room order", %{conn: conn} do
    response = conn |> submit([open_operation()]) |> json_response(200)

    assert response == %{
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

    group = get(conn, "/api/v1/groups/group-81") |> json_response(200)

    assert group["data"] == %{
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

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "processes a batch in order and continues after a stale rejection", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        operation_id: "pay-1",
        type: "record_cash_payment",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        amount_cents: 5_000,
        expected_revision: 1
      },
      %{
        operation_id: "pay-stale",
        type: "record_cash_payment",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        amount_cents: 1,
        expected_revision: 1
      },
      %{
        operation_id: "move-1",
        type: "reschedule_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        new_arrival_on: "2026-12-20",
        expected_revision: 2
      },
      %{
        operation_id: "cancel-1",
        type: "cancel_group",
        occurred_on: "2026-12-01",
        group_id: "group-81",
        expected_revision: 3
      },
      %{
        operation_id: "pay-inactive",
        type: "record_cash_payment",
        occurred_on: "2026-12-01",
        group_id: "group-81",
        amount_cents: 1
      }
    ]

    results = submit(conn, operations) |> json_response(200) |> Map.fetch!("results")

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "applied",
             "rejected",
             "applied",
             "applied",
             "rejected"
           ]

    assert Enum.at(results, 1) == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_500,
             "revision" => 2
           }

    assert Enum.at(results, 2) == %{
             "operation_id" => "pay-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert Enum.at(results, 3)["new_departure_on"] == "2026-12-23"
    assert Enum.at(results, 4)["refunded_cents"] == 5_000
    assert Enum.at(results, 5)["code"] == "group_not_active"

    assert get(conn, "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           }
  end

  test "validates operations and rounds each flexible room independently", %{conn: conn} do
    results =
      submit(conn, [
        open_operation(%{
          operation_id: "round-1",
          group_id: "rounding",
          arrival_on: "2026-11-01",
          departure_on: "2026-11-02",
          rooms: [
            %{room_id: "one", nightly_rate_cents: 3},
            %{room_id: "two", nightly_rate_cents: 7}
          ]
        }),
        open_operation(%{operation_id: "bad-rooms", group_id: "bad", rooms: []}),
        %{operation_id: "unknown", type: "explode"},
        %{operation_id: "missing-group", type: "cancel_group"}
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 0)["deposit_due_cents"] == 2
    assert Enum.at(results, 0)["revision"] == 1
    assert Enum.at(results, 1)["code"] == "invalid_rooms"
    assert Enum.at(results, 2)["code"] == "invalid_operation"
    assert Enum.at(results, 3)["code"] == "invalid_operation"

    assert get(conn, "/api/v1/groups/bad") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "advance purchase cancellation retains cash and invalid batches use 422", %{conn: conn} do
    open = open_operation(%{group_id: "advance", rate_plan: "advance_purchase"})

    submit(conn, [
      open,
      %{
        operation_id: "pay-advance",
        type: "record_cash_payment",
        occurred_on: "2026-10-03",
        group_id: "advance",
        amount_cents: 1_000
      }
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "cancel-advance",
          type: "cancel_group",
          occurred_on: "2026-10-03",
          group_id: "advance"
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 1_000

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 1_000
             }
           }

    conn = put_req_header(conn, "content-type", "application/json")

    assert post(conn, "/api/v1/partner-batches", Jason.encode!(%{})) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }
  end

  test "a missing group is resolved before its expected revision", %{conn: conn} do
    result =
      submit(conn, [
        %{
          operation_id: "missing",
          type: "cancel_group",
          occurred_on: "not-a-date",
          group_id: "does-not-exist",
          expected_revision: 99
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "missing",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "does-not-exist"
           }
  end

  test "refunds exactly 14 days before arrival and retains later cancellations", %{conn: conn} do
    open_one = open_operation(%{group_id: "boundary-refund", guest_id: "guest-refund"})
    open_two = open_operation(%{group_id: "boundary-retain", guest_id: "guest-retain"})

    submit(conn, [open_one, open_two]) |> json_response(200)

    payment = fn group_id, operation_id ->
      %{
        operation_id: operation_id,
        type: "record_cash_payment",
        occurred_on: "2026-10-03",
        group_id: group_id,
        amount_cents: 1_000
      }
    end

    submit(conn, [
      payment.("boundary-refund", "pay-refund"),
      payment.("boundary-retain", "pay-retain")
    ])
    |> json_response(200)

    results =
      submit(conn, [
        %{
          operation_id: "cancel-boundary-refund",
          type: "cancel_group",
          occurred_on: "2026-11-26",
          group_id: "boundary-refund"
        },
        %{
          operation_id: "cancel-boundary-retain",
          type: "cancel_group",
          occurred_on: "2026-11-27",
          group_id: "boundary-retain"
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 0)["refunded_cents"] == 1_000
    assert Enum.at(results, 0)["retained_cents"] == 0
    assert Enum.at(results, 1)["refunded_cents"] == 0
    assert Enum.at(results, 1)["retained_cents"] == 1_000
  end

  test "invalid payments and moves do not change group revision or ledger", %{conn: conn} do
    submit(conn, [open_operation(%{group_id: "unchanged"})]) |> json_response(200)

    results =
      submit(conn, [
        %{
          operation_id: "zero-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-03",
          group_id: "unchanged",
          amount_cents: 0
        },
        %{
          operation_id: "too-much",
          type: "record_cash_payment",
          occurred_on: "2026-10-03",
          group_id: "unchanged",
          amount_cents: 20_000
        },
        %{
          operation_id: "invalid-move",
          type: "reschedule_group",
          occurred_on: "2026-10-03",
          group_id: "unchanged",
          new_arrival_on: "2026-10-03"
        },
        %{
          operation_id: "stale-invalid-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-03",
          group_id: "unchanged",
          amount_cents: 20_000,
          expected_revision: 0
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.map(results, & &1["code"]) == [
             "invalid_amount",
             "payment_exceeds_outstanding",
             "invalid_stay",
             "stale_revision"
           ]

    assert get(conn, "/api/v1/groups/unchanged")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end
end
