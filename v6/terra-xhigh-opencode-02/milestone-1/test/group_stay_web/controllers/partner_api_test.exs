defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  test "opens a group, preserves room order, and reports empty finance totals", %{conn: conn} do
    response = post_batch(conn, [open_group()])

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           }

    group =
      conn
      |> get("/api/v1/groups/group-1")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group == %{
             "group_id" => "group-1",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 1,
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "processes operations in order and continues after a rejected operation", %{conn: conn} do
    response =
      post_batch(conn, [
        open_group(),
        cash_payment("pay-1", 1_000, 1),
        cash_payment("too-much", 19_000, 2),
        reschedule("move-1", "2026-12-14", 2)
      ])

    assert [
             %{"status" => "applied", "revision" => 1},
             %{
               "status" => "applied",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 18_500,
               "revision" => 2
             },
             %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
             %{
               "status" => "applied",
               "new_arrival_on" => "2026-12-14",
               "new_departure_on" => "2026-12-17",
               "revision" => 3
             }
           ] = response["results"]

    group = group(conn, "group-1")
    assert group["arrival_on"] == "2026-12-14"
    assert group["departure_on"] == "2026-12-17"
    assert group["revision"] == 3
    assert group["outstanding_deposit_cents"] == 18_500
  end

  test "checks a supplied revision before all other group validation", %{conn: conn} do
    post_batch(conn, [open_group(), cash_payment("pay-1", 500, 1)])

    response = post_batch(conn, [cash_payment("stale-1", 999_999, 1)])

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "stale-1",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           }

    assert group(conn, "group-1")["revision"] == 2
    assert ledger(conn)["cash_held_cents"] == 500
  end

  test "calculates flexible deposits per room with half-up rounding", %{conn: conn} do
    response =
      post_batch(conn, [
        open_group("rounding", %{
          "group_id" => "rounding-group",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "rounding-a", "nightly_rate_cents" => 3},
            %{"room_id" => "rounding-b", "nightly_rate_cents" => 3}
          ]
        }),
        open_group("advance", %{
          "group_id" => "advance-group",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "advance-room", "nightly_rate_cents" => 123}]
        })
      ])

    assert [
             %{"group_id" => "rounding-group", "deposit_due_cents" => 2},
             %{"group_id" => "advance-group", "deposit_due_cents" => 123}
           ] = response["results"]
  end

  test "validates opening and payment failures without creating or changing a group", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_group("bad-stay", %{"arrival_on" => "2026-12-13"}),
        open_group("bad-rooms", %{"rooms" => []}),
        open_group("bad-rate", %{"rate_plan" => "standard"}),
        open_group(),
        open_group("duplicate", %{"group_id" => "group-1"}),
        cash_payment("zero", 0, 1),
        cash_payment("excess", 19_501, 1),
        cash_payment("missing-group", 1, 99, "missing"),
        %{"operation_id" => "unknown", "type" => "unknown_operation"},
        %{
          "operation_id" => "incomplete-move",
          "type" => "reschedule_group",
          "group_id" => "group-1",
          "occurred_on" => "2026-10-04"
        }
      ])

    assert Enum.map(response["results"], & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan",
             nil,
             "group_already_exists",
             "invalid_amount",
             "payment_exceeds_outstanding",
             "group_not_found",
             "invalid_operation",
             "invalid_operation"
           ]

    assert group(conn, "group-1")["revision"] == 1
    assert group(conn, "group-1")["deposit_paid_cents"] == 0

    assert get(conn, "/api/v1/groups/bad-stay") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "cancellation settles flexible and advance-purchase cash and locks the group", %{
    conn: conn
  } do
    cancellation_results =
      post_batch(conn, [
        open_group("flex", %{"group_id" => "flex-group"}),
        cash_payment("flex-pay", 1_000, 1, "flex-group"),
        cancel("flex-cancel", "2026-11-26", 2, "flex-group"),
        open_group("advance", %{"group_id" => "advance-group", "rate_plan" => "advance_purchase"}),
        cash_payment("advance-pay", 2_000, 1, "advance-group"),
        cancel("advance-cancel", "2026-11-26", 2, "advance-group")
      ])

    assert %{"refunded_cents" => 1_000, "retained_cents" => 0, "revision" => 3} =
             Enum.at(cancellation_results["results"], 2)

    assert %{"refunded_cents" => 0, "retained_cents" => 2_000, "revision" => 3} =
             Enum.at(cancellation_results["results"], 5)

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 1_000,
             "cash_retained_cents" => 2_000
           }

    assert %{
             "status" => "cancelled",
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 1_000,
             "outstanding_deposit_cents" => 0,
             "revision" => 3
           } = group(conn, "flex-group")

    response =
      post_batch(conn, [
        cash_payment("stale-after-cancel", 1, 2, "flex-group"),
        reschedule("move-after-cancel", "2026-12-14", nil, "flex-group")
      ])

    assert [
             %{
               "code" => "stale_revision",
               "expected_revision" => 2,
               "actual_revision" => 3
             },
             %{"code" => "group_not_active"}
           ] = response["results"]
  end

  test "rejects an invalid batch and returns missing groups as documented", %{conn: conn} do
    assert post(conn, "/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert get(conn, "/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  defp open_group(operation_id \\ "open-1", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
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

  defp cash_payment(operation_id, amount_cents, expected_revision, group_id \\ "group-1") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp reschedule(operation_id, new_arrival_on, expected_revision, group_id \\ "group-1") do
    operation = %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }

    if is_nil(expected_revision),
      do: operation,
      else: Map.put(operation, "expected_revision", expected_revision)
  end

  defp cancel(operation_id, occurred_on, expected_revision, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
