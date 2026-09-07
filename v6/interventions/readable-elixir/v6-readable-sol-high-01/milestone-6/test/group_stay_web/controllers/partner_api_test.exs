defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})
    end

    test "opens a group and preserves room order in the read model", %{conn: conn} do
      result = submit_one(conn, open_operation())

      assert result == %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
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
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit independently", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "a", "nightly_rate_cents" => 102},
            %{"room_id" => "b", "nightly_rate_cents" => 102}
          ]
        })

      assert %{"deposit_due_cents" => 40} = submit_one(conn, operation)
    end

    test "uses the full lodging total for advance purchase", %{conn: conn} do
      operation = open_operation(%{"rate_plan" => "advance_purchase"})

      assert %{"deposit_due_cents" => 97_500} = submit_one(conn, operation)
    end

    test "rejects invalid groups without persisting them", %{conn: conn} do
      invalid_operations = [
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
        open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "semi-flex"}),
        open_operation(%{
          "operation_id" => "bad-rooms",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => invalid_operations})

      assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) == [
               "invalid_stay",
               "invalid_rate_plan",
               "invalid_rooms"
             ]

      assert get(conn, "/api/v1/groups/group-81") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "processes operations in order and continues after a rejection", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"operation_id" => "too-much", "amount_cents" => 20_000}),
        payment_operation(%{"operation_id" => "pay-1", "amount_cents" => 5_000}),
        payment_operation(%{
          "operation_id" => "pay-2",
          "amount_cents" => 14_500,
          "expected_revision" => 2
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert [opened, rejected, first_payment, second_payment] =
               json_response(conn, 200)["results"]

      assert opened["revision"] == 1
      assert rejected["code"] == "payment_exceeds_outstanding"
      assert first_payment["revision"] == 2
      assert first_payment["outstanding_deposit_cents"] == 14_500
      assert second_payment["revision"] == 3
      assert second_payment["outstanding_deposit_cents"] == 0
    end

    test "checks a stale revision before other validation and changes no state", %{conn: conn} do
      submit_one(conn, open_operation())

      operation =
        payment_operation(%{
          "amount_cents" => -10,
          "expected_revision" => 9
        })

      assert submit_one(conn, operation) == %{
               "operation_id" => "pay-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      assert get(conn, "/api/v1/groups/group-81")
             |> json_response(200)
             |> get_in(["data", "revision"]) ==
               1

      assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "reschedules by preserving the stay length and price", %{conn: conn} do
      submit_one(conn, open_operation())

      result =
        submit_one(conn, %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-20",
          "group_id" => "group-81",
          "new_arrival_on" => "2027-01-15",
          "expected_revision" => 1
        })

      assert result == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-01-15",
               "new_departure_on" => "2027-01-18",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-01",
               "revision" => 2
             }

      group = get(conn, "/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "requires a rescheduled arrival to be after the operation date", %{conn: conn} do
      submit_one(conn, open_operation())

      result =
        submit_one(conn, %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-15",
          "group_id" => "group-81",
          "new_arrival_on" => "2027-01-15"
        })

      assert result["code"] == "invalid_stay"
    end

    test "refunds timely flexible cancellations and clears held cash", %{conn: conn} do
      submit_one(conn, open_operation())
      submit_one(conn, payment_operation(%{"amount_cents" => 10_000}))

      assert get(conn, "/api/v1/ledger")
             |> json_response(200)
             |> get_in(["data", "cash_held_cents"]) ==
               10_000

      result =
        submit_one(conn, %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "expected_revision" => 2
        })

      assert result["refunded_cents"] == 10_000
      assert result["retained_cents"] == 0
      assert result["revision"] == 3

      assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }

      group = get(conn, "/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
    end

    test "retains late flexible and all advance-purchase cash", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"amount_cents" => 1_000}),
        %{
          "operation_id" => "late-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81"
        },
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance-group",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation(%{
          "operation_id" => "advance-pay",
          "group_id" => "advance-group",
          "amount_cents" => 2_000
        }),
        %{
          "operation_id" => "early-advance-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "advance-group"
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      results = json_response(conn, 200)["results"]

      assert Enum.at(results, 2)["retained_cents"] == 1_000
      assert Enum.at(results, 5)["retained_cents"] == 2_000

      assert get(conn, "/api/v1/ledger")
             |> json_response(200)
             |> get_in(["data", "cash_retained_cents"]) ==
               3_000
    end

    test "rejects later operations for a cancelled group", %{conn: conn} do
      submit_one(conn, open_operation())

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "group-81"
      })

      result = submit_one(conn, payment_operation(%{"expected_revision" => 2}))
      assert result["code"] == "group_not_active"
    end

    test "resolves group existence before revision checks", %{conn: conn} do
      result =
        submit_one(
          conn,
          payment_operation(%{
            "group_id" => "missing",
            "expected_revision" => 99
          })
        )

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "missing"
    end

    test "rejects duplicate groups and structurally invalid operations", %{conn: conn} do
      submit_one(conn, open_operation())

      assert submit_one(conn, open_operation(%{"operation_id" => "again"}))["code"] ==
               "group_already_exists"

      conn =
        post(conn, "/api/v1/partner-batches", %{
          "operations" => [
            %{"operation_id" => "unknown", "type" => "dance"},
            %{"operation_id" => "missing-type"},
            "not-an-operation"
          ]
        })

      assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) ==
               List.duplicate("invalid_operation", 3)
    end

    test "uses invalid_operation when a known operation is missing required data", %{conn: conn} do
      submit_one(conn, open_operation())

      missing_open_data =
        open_operation(%{"operation_id" => "missing-open-data", "group_id" => "group-2"})
        |> Map.delete("rooms")

      missing_payment_data = payment_operation(%{}) |> Map.delete("amount_cents")

      missing_reschedule_data = %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      }

      conn =
        post(conn, "/api/v1/partner-batches", %{
          "operations" => [
            missing_open_data,
            missing_payment_data,
            missing_reschedule_data
          ]
        })

      assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) ==
               List.duplicate("invalid_operation", 3)
    end
  end

  describe "GET read endpoints" do
    test "returns the empty ledger and a stable missing-group error", %{conn: conn} do
      assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }

      assert get(conn, "/api/v1/groups/no-such-group") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  defp submit_one(conn, operation) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => [operation]})
    |> json_response(200)
    |> get_in(["results", Access.at(0)])
  end

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

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end
end
