defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
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
          %{room_id: "room-a", nightly_rate_cents: 101},
          %{room_id: "room-b", nightly_rate_cents: 103}
        ]
      },
      overrides
    )
  end

  test "opens groups, processes operations in order, and settles refundable cash", %{conn: conn} do
    response =
      post_batch(conn, [
        open_operation(),
        %{
          operation_id: "pay-1",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 123,
          expected_revision: 1
        },
        %{
          operation_id: "move-1",
          type: "reschedule_group",
          occurred_on: "2026-10-05",
          group_id: "group-81",
          new_arrival_on: "2026-12-20",
          expected_revision: 2
        },
        %{
          operation_id: "cancel-1",
          type: "cancel_group",
          occurred_on: "2026-12-06",
          group_id: "group-81",
          expected_revision: 3
        }
      ])
      |> json_response(200)

    assert [
             %{"status" => "applied", "deposit_due_cents" => 123, "revision" => 1},
             %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2},
             %{
               "status" => "applied",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 3
             },
             %{
               "status" => "applied",
               "refunded_cents" => 123,
               "retained_cents" => 0,
               "revision" => 4
             }
           ] = response["results"]

    group =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["status"] == "cancelled"
    assert group["revision"] == 4
    assert group["lodging_total_cents"] == 612
    assert group["deposit_paid_cents"] == 123
    assert group["outstanding_deposit_cents"] == 0
    assert Enum.map(group["rooms"], & &1["room_id"]) == ["room-a", "room-b"]

    ledger =
      conn
      |> get("/api/v1/ledger")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 123,
             "cash_retained_cents" => 0
           }
  end

  test "rejections do not change the group and stale revisions precede domain validation", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_operation(),
        %{
          operation_id: "too-much",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 124,
          expected_revision: 1
        },
        %{
          operation_id: "valid-pay",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 100,
          expected_revision: 1
        },
        %{
          operation_id: "stale-invalid-pay",
          type: "record_cash_payment",
          occurred_on: "not-a-date",
          group_id: "group-81",
          amount_cents: -10,
          expected_revision: 1
        }
      ])
      |> json_response(200)

    assert Enum.map(response["results"], & &1["status"]) == [
             "applied",
             "rejected",
             "applied",
             "rejected"
           ]

    assert response["results"] |> Enum.at(1) |> Map.fetch!("code") ==
             "payment_exceeds_outstanding"

    assert response["results"] |> Enum.at(3) == %{
             "operation_id" => "stale-invalid-pay",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    group =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["revision"] == 2
    assert group["deposit_paid_cents"] == 100

    assert conn
           |> get("/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_held_cents"]) == 100
  end

  test "advance purchase cancellation retains cash and later mutations are rejected", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_operation(%{
          group_id: "advance-group",
          rate_plan: "advance_purchase",
          rooms: [%{room_id: "room-a", nightly_rate_cents: 1000}]
        }),
        %{
          operation_id: "pay-advance",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "advance-group",
          amount_cents: 3000
        },
        %{
          operation_id: "cancel-advance",
          type: "cancel_group",
          occurred_on: "2026-10-04",
          group_id: "advance-group"
        },
        %{
          operation_id: "pay-cancelled",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "advance-group",
          amount_cents: 1
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 0)["deposit_due_cents"] == 3000
    assert Enum.at(response["results"], 2)["retained_cents"] == 3000
    assert Enum.at(response["results"], 3)["code"] == "group_not_active"

    ledger =
      conn
      |> get("/api/v1/ledger")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 3000
           }
  end

  test "late flexible cancellation retains paid cash and releases unpaid deposit", %{conn: conn} do
    response =
      post_batch(conn, [
        open_operation(%{group_id: "late-flexible-group"}),
        %{
          operation_id: "pay-late",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "late-flexible-group",
          amount_cents: 50
        },
        %{
          operation_id: "cancel-late",
          type: "cancel_group",
          occurred_on: "2026-12-09",
          group_id: "late-flexible-group"
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 2)["refunded_cents"] == 0
    assert Enum.at(response["results"], 2)["retained_cents"] == 50

    group =
      conn
      |> get("/api/v1/groups/late-flexible-group")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["deposit_paid_cents"] == 50
    assert group["outstanding_deposit_cents"] == 0
  end

  test "uses the documented opening validation codes", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation(%{group_id: "bad-stay", arrival_on: "2026-12-13"}),
        open_operation(%{
          group_id: "bad-rooms",
          rooms: [
            %{room_id: "duplicate", nightly_rate_cents: 100},
            %{room_id: "duplicate", nightly_rate_cents: 200}
          ]
        }),
        open_operation(%{group_id: "bad-plan", rate_plan: "nonrefundable"})
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.map(results, & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan"
           ]
  end

  test "rejects an invalid batch and reports missing groups", %{conn: conn} do
    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", Jason.encode!(%{operations: "not-an-array"}))
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}

    assert conn
           |> get("/api/v1/groups/missing-group")
           |> json_response(404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
