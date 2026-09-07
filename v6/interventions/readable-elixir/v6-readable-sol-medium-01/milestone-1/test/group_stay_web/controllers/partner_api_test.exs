defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{})

      assert response(conn, 422) == Jason.encode!(%{error: %{code: "invalid_batch"}})
    end

    test "opens a group and exposes its rooms and calculated totals", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        })

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [operation]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 19_501,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(recycle(conn), ~p"/api/v1/groups/group-1")

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
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_503,
                 "deposit_due_cents" => 19_501,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_501
               }
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit before summing", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3}
          ]
        })

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [operation]})

      assert %{"results" => [%{"deposit_due_cents" => 2}]} = json_response(conn, 200)
    end

    test "processes operations in order and continues after rejection", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay-1", 10_000, 1),
        payment_operation("too-much", 100_000, 2),
        payment_operation("pay-2", 9_500, 2)
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected", "applied"]
      assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"
      assert Enum.at(results, 3)["revision"] == 3
      assert Enum.at(results, 3)["outstanding_deposit_cents"] == 0
    end

    test "checks existence and revision before other payment validation", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "missing",
          "type" => "record_cash_payment",
          "occurred_on" => "not-a-date",
          "group_id" => "does-not-exist",
          "expected_revision" => 99
        },
        %{
          "operation_id" => "stale",
          "type" => "record_cash_payment",
          "occurred_on" => "not-a-date",
          "group_id" => "group-1",
          "expected_revision" => 0
        }
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, missing, stale]} = json_response(conn, 200)
      assert missing["code"] == "group_not_found"

      assert stale == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 0,
               "actual_revision" => 1
             }
    end

    test "reschedules by preserving stay length and increments revision", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1",
          "new_arrival_on" => "2027-01-15",
          "expected_revision" => 1
        }
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["new_arrival_on"] == "2027-01-15"
      assert result["new_departure_on"] == "2027-01-18"
      assert result["revision"] == 2
    end

    test "refunds timely flexible cancellations and moves cash through the ledger", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay-1", 10_000, 1),
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-1",
          "expected_revision" => 2
        },
        payment_operation("late-pay", 1, 3)
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, _, cancellation, rejected]} = json_response(conn, 200)
      assert cancellation["refunded_cents"] == 10_000
      assert cancellation["retained_cents"] == 0
      assert cancellation["revision"] == 3
      assert rejected["code"] == "group_not_active"

      conn = get(recycle(conn), ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "retains late flexible and all advance-purchase payments", %{conn: conn} do
      advance =
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance-group",
          "rate_plan" => "advance_purchase"
        })

      operations = [
        open_operation(),
        payment_operation("flex-pay", 5_000, 1),
        cancel_operation("flex-cancel", "group-1", "2026-11-27", 2),
        advance,
        payment_operation("advance-pay", 7_000, 1, "advance-group"),
        cancel_operation("advance-cancel", "advance-group", "2026-10-04", 2)
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 2)["retained_cents"] == 5_000
      assert Enum.at(results, 5)["retained_cents"] == 7_000

      conn = get(recycle(conn), ~p"/api/v1/ledger")
      assert get_in(json_response(conn, 200), ["data", "cash_retained_cents"]) == 12_000
    end

    test "rejects invalid opening data without reserving the group identifier", %{conn: conn} do
      invalid = open_operation(%{"rooms" => []})
      valid = open_operation(%{"operation_id" => "retry"})

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [invalid, valid]})

      assert %{"results" => [first, second]} = json_response(conn, 200)
      assert first["code"] == "invalid_rooms"
      assert second["status"] == "applied"
    end

    test "rejects duplicate groups, invalid stays, rate plans, amounts and operations", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        open_operation(%{"operation_id" => "duplicate"}),
        open_operation(%{
          "operation_id" => "bad-stay",
          "group_id" => "bad-stay",
          "departure_on" => "2026-12-10"
        }),
        open_operation(%{
          "operation_id" => "bad-plan",
          "group_id" => "bad-plan",
          "rate_plan" => "mystery"
        }),
        payment_operation("bad-amount", 0, 1),
        %{"operation_id" => "unknown", "type" => "unknown", "occurred_on" => "2026-10-03"}
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) == [
               nil,
               "group_already_exists",
               "invalid_stay",
               "invalid_rate_plan",
               "invalid_amount",
               "invalid_operation"
             ]
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the documented missing-group error", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/groups/unknown")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
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
      },
      overrides
    )
  end

  defp payment_operation(operation_id, amount, revision, group_id \\ "group-1") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => revision
    }
  end
end
