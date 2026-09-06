defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  ## helpers

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
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

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  ## batch envelope

  describe "batch envelope" do
    test "missing operations array is an invalid batch", %{conn: conn} do
      conn = post_batch(conn, %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "non-list operations is an invalid batch", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => %{"operation_id" => "op-1"}})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "unknown operation type is rejected with invalid_operation", %{conn: conn} do
      conn =
        post_batch(conn, %{"operations" => [%{"operation_id" => "op-1", "type" => "hold_room"}]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "operation missing identifying fields is rejected with invalid_operation", %{conn: conn} do
      operations = [
        Map.delete(open_op(), "group_id"),
        Map.delete(open_op(), "guest_id"),
        Map.delete(payment_op(), "group_id"),
        Map.delete(cancel_op(), "occurred_on"),
        Map.delete(open_op(), "operation_id")
      ]

      conn = post_batch(conn, %{"operations" => operations})
      %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["status"]) == ~w(rejected rejected rejected rejected rejected)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_operation", 5)
    end

    test "results are returned in operation order and a rejection does not stop the batch",
         %{conn: conn} do
      operations = [
        open_op(%{"operation_id" => "op-1"}),
        payment_op(%{"operation_id" => "op-2", "group_id" => "group-missing"}),
        open_op(%{
          "operation_id" => "op-3",
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert [first, second, third] = results
      assert first["operation_id"] == "op-1"
      assert first["status"] == "applied"
      assert second["operation_id"] == "op-2"
      assert second["status"] == "rejected"
      assert second["code"] == "group_not_found"
      assert third["operation_id"] == "op-3"
      assert third["status"] == "applied"
    end

    test "an operation observes changes made by an earlier operation in the same batch",
         %{conn: conn} do
      operations = [
        open_op(%{"operation_id" => "op-1"}),
        payment_op(%{"operation_id" => "op-2", "amount_cents" => 19_500})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, payment]} = json_response(conn, 200)
      assert payment["status"] == "applied"
      assert payment["outstanding_deposit_cents"] == 0
      assert payment["revision"] == 2
    end
  end

  ## open_group

  describe "open_group" do
    test "applies the API document example", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end

    test "rounds each room's flexible deposit separately, half-cents up", %{conn: conn} do
      # two nights: room-a lodging 3002 -> deposit 600.4 -> 600; room-b lodging 3003 -> 600.6 -> 601
      conn =
        post_batch(conn, %{
          "operations" => [
            open_op(%{
              "departure_on" => "2026-12-12",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 1501},
                %{"room_id" => "room-b", "nightly_rate_cents" => 1501.5 + 0.5}
              ]
            })
          ]
        })

      %{"results" => [first]} = json_response(conn, 200)
      # second room is fractional and must be rejected
      assert first["code"] == "invalid_rooms"

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{
              "departure_on" => "2026-12-12",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 1501},
                %{"room_id" => "room-b", "nightly_rate_cents" => 1502}
              ]
            })
          ]
        })

      %{"results" => [result]} = json_response(conn, 200)
      # room-a: 2 * 1501 = 3002 lodging, 20% = 600.4 -> 600
      # room-b: 2 * 1502 = 3004 lodging, 20% = 600.8 -> 601
      assert result["status"] == "applied"
      assert result["deposit_due_cents"] == 1201
    end

    test "advance purchase requires the full lodging amount", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [open_op(%{"rate_plan" => "advance_purchase"})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      # full lodging: 3 * 15000 + 3 * 17500
      assert result["deposit_due_cents"] == 97_500
    end

    test "rejects an existing group identifier", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op()]})
      conn = post_batch(conn, %{"operations" => [open_op(%{"operation_id" => "op-again"})]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "rejected"
      assert result["code"] == "group_already_exists"

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 1
    end

    test "rejects stays without a night", %{conn: conn} do
      operations = [
        open_op(%{"departure_on" => "2026-12-10", "operation_id" => "op-1"}),
        open_op(%{
          "arrival_on" => "2026-12-13",
          "departure_on" => "2026-12-10",
          "operation_id" => "op-2"
        }),
        open_op(%{"departure_on" => "not-a-date", "operation_id" => "op-3"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == ~w(invalid_stay invalid_stay invalid_stay)
    end

    test "rejects unusable room lists", %{conn: conn} do
      operations = [
        open_op(%{"rooms" => [], "operation_id" => "op-1"}),
        open_op(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 150},
            %{"room_id" => "room-a", "nightly_rate_cents" => 200}
          ],
          "operation_id" => "op-2"
        }),
        open_op(%{"rooms" => [%{"room_id" => "room-a"}], "operation_id" => "op-3"}),
        open_op(%{
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}],
          "operation_id" => "op-4"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_rooms", 4)
    end

    test "rejects unknown rate plans", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op(%{"rate_plan" => "weekend"})]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "invalid_rate_plan"
    end

    test "ignored expected_revision and books the group on occurred_on", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [open_op(%{"expected_revision" => 7})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["revision"] == 1

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["booked_on"] == "2026-10-03"
    end
  end

  ## record_cash_payment

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_500})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 19_500,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }
    end

    test "rejects missing groups", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [payment_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end

    test "rejects unusable amounts", %{conn: conn} do
      operations = [
        payment_op(%{"amount_cents" => 0, "operation_id" => "op-1"}),
        payment_op(%{"amount_cents" => -100, "operation_id" => "op-2"}),
        payment_op(%{"amount_cents" => "5000", "operation_id" => "op-3"}),
        Map.delete(payment_op(), "amount_cents") |> Map.put("operation_id", "op-4")
      ]

      conn =
        post_batch(conn, %{
          "operations" => [open_op(%{"operation_id" => "op-open"}) | operations]
        })

      assert %{"results" => [_open | results]} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_amount", 4)

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "rejects payments above the outstanding deposit", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_501})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["code"] == "payment_exceeds_outstanding"
    end
  end

  ## reschedule_group

  describe "reschedule_group" do
    test "shifts the stay without changing its length or price", %{conn: conn} do
      operations = [
        open_op(),
        reschedule_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 2
             }
    end

    test "allows moving the stay earlier when it stays after the operation date",
         %{conn: conn} do
      operations = [
        open_op(),
        reschedule_op(%{"new_arrival_on" => "2026-12-01"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["new_arrival_on"] == "2026-12-01"
      assert result["new_departure_on"] == "2026-12-04"
    end

    test "rejects unusable dates", %{conn: conn} do
      operations = [
        open_op(),
        # equal to the operation date is not after it
        reschedule_op(%{"new_arrival_on" => "2026-10-05", "operation_id" => "op-1"}),
        # before the operation date
        reschedule_op(%{"new_arrival_on" => "2026-10-01", "operation_id" => "op-2"}),
        # not a date
        reschedule_op(%{"new_arrival_on" => "later", "operation_id" => "op-3"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_open | results]} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == ~w(invalid_stay invalid_stay invalid_stay)
    end

    test "rejects missing groups", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [reschedule_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end
  end

  ## cancel_group

  describe "cancel_group" do
    test "refunds cash for flexible groups cancelled at least 14 days before arrival",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 3
             }
    end

    test "retains cash for flexible groups cancelled inside the notice window",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        # 13 days before arrival 2026-12-10
        cancel_op(%{"occurred_on" => "2026-11-27"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
    end

    test "always retains cash for advance purchase groups", %{conn: conn} do
      operations = [
        open_op(%{"rate_plan" => "advance_purchase"}),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
    end

    test "forgives the unpaid remainder and blocks later operations", %{conn: conn} do
      operations = [
        open_op(),
        cancel_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      later = [
        payment_op(%{"operation_id" => "op-after-pay"}),
        reschedule_op(%{"operation_id" => "op-after-move"}),
        cancel_op(%{"operation_id" => "op-after-cancel"})
      ]

      conn = post_batch(build_conn(), %{"operations" => later})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) ==
               ~w(group_not_active group_not_active group_not_active)

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      # rejected operations do not move the revision
      assert group["revision"] == 2
    end

    test "rejects missing groups", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [cancel_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end
  end

  ## concurrent updates

  describe "revisions" do
    test "each applied operation increments the revision exactly once", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 5_000}),
        reschedule_op(),
        payment_op(%{"amount_cents" => 1_000, "operation_id" => "op-second-pay"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    end

    test "applies when expected_revision matches", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"expected_revision" => 1, "amount_cents" => 5_000}),
        payment_op(%{
          "expected_revision" => 2,
          "amount_cents" => 1_000,
          "operation_id" => "op-more"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, first, second]} = json_response(conn, 200)
      assert first["status"] == "applied"
      assert first["revision"] == 2
      assert second["status"] == "applied"
      assert second["revision"] == 3
    end

    test "rejects a stale revision before other validation and reports both revisions",
         %{conn: conn} do
      operations = [
        open_op(),
        # stale but otherwise valid
        payment_op(%{"expected_revision" => 4, "operation_id" => "op-1"}),
        # stale and also above the outstanding deposit: the revision must win
        payment_op(%{
          "expected_revision" => 3,
          "amount_cents" => 1_000_000,
          "operation_id" => "op-2"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, first, second]} = json_response(conn, 200)

      assert first == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 4,
               "actual_revision" => 1
             }

      assert second["code"] == "stale_revision"
      assert second["expected_revision"] == 3
      assert second["actual_revision"] == 1

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "group existence is resolved before revisions are compared", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [payment_op(%{"expected_revision" => 9, "group_id" => "group-other"})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end

    test "expected revision still applies to a cancelled group", %{conn: conn} do
      operations = [
        open_op(),
        cancel_op(),
        payment_op(%{
          "expected_revision" => 1,
          "amount_cents" => 100,
          "operation_id" => "op-stale"
        }),
        payment_op(%{
          "expected_revision" => 2,
          "amount_cents" => 100,
          "operation_id" => "op-fresh"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, stale, fresh]} = json_response(conn, 200)
      assert stale["code"] == "stale_revision"
      assert fresh["code"] == "group_not_active"
    end
  end
end
