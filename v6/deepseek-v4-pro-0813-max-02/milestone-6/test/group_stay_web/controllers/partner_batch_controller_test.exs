defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  @open_group %{
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
      %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
    ]
  }

  describe "batch shape" do
    test "a body without an operations array is an invalid batch" do
      conn = build_conn() |> put_req_header("content-type", "application/json")

      conn = post(conn, "/api/v1/partner-batches", Jason.encode!(%{}))
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(conn, "/api/v1/partner-batches", Jason.encode!(%{"operations" => "nope"}))
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "an empty operations array yields an empty results array" do
      {body, status} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => []})
      assert status == 200
      assert body == %{"results" => []}
    end
  end

  describe "open_group" do
    test "opens a flexible group like the API example" do
      {body, status} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      assert status == 200

      assert body == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      {group, 200} = api_get(build_conn(), "/api/v1/groups/group-81")
      assert %{"data" => data} = group

      assert data == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15_000,
                   "status" => "active",
                   "deposit_due_cents" => 9_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17_500,
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
    end

    test "rounds each flexible room's deposit separately before summing" do
      op =
        open_group_op(%{
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 33_334},
            %{"room_id" => "room-b", "nightly_rate_cents" => 33_333}
          ]
        })

      {body, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})

      # Per room: 6666.8 -> 6667 and 6666.6 -> 6667, total 13334.
      # Rounding the 66667-cent total would give 13333 instead.
      assert Enum.at(body["results"], 0)["deposit_due_cents"] == 13_334

      op =
        open_group_op(%{
          "operation_id" => "op-1009",
          "group_id" => "group-82",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 33_332}]
        })

      {body, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})

      # 6666.4 rounds down to 6666.
      assert Enum.at(body["results"], 0)["deposit_due_cents"] == 6_666
    end

    test "advance-purchase rooms require their full lodging amount" do
      op =
        open_group_op(%{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })

      {body, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})
      assert Enum.at(body["results"], 0)["deposit_due_cents"] == 45_000
    end

    test "uses occurred_on as the booked_on date" do
      op = open_group_op(%{"occurred_on" => "2026-11-05"})

      {_, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})
      {body, 200} = api_get(build_conn(), "/api/v1/groups/group-81")
      assert body["data"]["booked_on"] == "2026-11-05"
    end

    test "rejects a duplicate group id with group_already_exists" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [open_group_op(%{"operation_id" => "op-1002"})]
        })

      assert body == %{
               "results" => [
                 %{
                   "operation_id" => "op-1002",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             }
    end

    test "rejects unusable stay dates with invalid_stay" do
      for {bad, index} <-
            Enum.with_index([
              %{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-10"},
              %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"},
              %{"arrival_on" => "not-a-date", "departure_on" => "2026-12-13"},
              %{"arrival_on" => "2026-12-10", "departure_on" => "2026-13-01"}
            ]) do
        {body, 200} =
          api_post(build_conn(), "/api/v1/partner-batches", %{
            "operations" => [open_group_op(Map.put(bad, "operation_id", "op-110#{index}"))]
          })

        assert Enum.at(body["results"], 0) == %{
                 "operation_id" => "op-110#{index}",
                 "status" => "rejected",
                 "code" => "invalid_stay"
               }
      end
    end

    test "rejects unusable rooms with invalid_rooms" do
      for {bad_rooms, index} <-
            Enum.with_index([
              [],
              [
                %{"room_id" => "room-a", "nightly_rate_cents" => 1},
                %{"room_id" => "room-a", "nightly_rate_cents" => 2}
              ],
              [%{"room_id" => "room-a"}],
              [%{"nightly_rate_cents" => 10_000}],
              [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
              [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
              [%{"room_id" => "room-a", "nightly_rate_cents" => 1.5}]
            ]) do
        {body, 200} =
          api_post(build_conn(), "/api/v1/partner-batches", %{
            "operations" => [
              open_group_op(%{
                "operation_id" => "op-120#{index}",
                "group_id" => "group-120#{index}",
                "rooms" => bad_rooms
              })
            ]
          })

        assert Enum.at(body["results"], 0)["code"] == "invalid_rooms",
               "expected invalid_rooms for #{inspect(bad_rooms)}"
      end

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [open_group_op(%{"operation_id" => "op-1299", "rooms" => "room-a"})]
        })

      assert Enum.at(body["results"], 0)["code"] == "invalid_rooms"
    end

    test "rejects unknown rate plans with invalid_rate_plan" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [open_group_op(%{"rate_plan" => "semi-flexible"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "invalid_rate_plan"
             }
    end

    test "ignores expected_revision on open_group" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [open_group_op(%{"expected_revision" => 42})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end
  end

  describe "invalid operations" do
    test "an unknown operation type is rejected with invalid_operation" do
      op = %{"operation_id" => "op-x", "type" => "close_group", "group_id" => "group-81"}

      {body, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})

      assert body == %{
               "results" => [
                 %{
                   "operation_id" => "op-x",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 }
               ]
             }
    end

    test "a non-object operation is rejected with invalid_operation" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [@open_group, 42, "op-1002"]
        })

      assert Enum.at(body["results"], 0)["status"] == "applied"

      assert Enum.at(body["results"], 1) == %{
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert Enum.at(body["results"], 2) == %{
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "operations missing required data are rejected with invalid_operation" do
      for {op, index} <-
            Enum.with_index([
              Map.delete(@open_group, "group_id"),
              Map.delete(@open_group, "occurred_on"),
              Map.delete(@open_group, "arrival_on"),
              Map.delete(@open_group, "departure_on"),
              Map.delete(@open_group, "rooms"),
              Map.delete(@open_group, "rate_plan"),
              Map.delete(@open_group, "guest_id"),
              Map.delete(@open_group, "property_id")
            ]) do
        {body, 200} =
          api_post(build_conn(), "/api/v1/partner-batches", %{
            "operations" => [Map.put(op, "operation_id", "op-130#{index}")]
          })

        assert Enum.at(body["results"], 0)["code"] == "invalid_operation",
               "expected invalid_operation for #{inspect(Map.put(op, "operation_id", "op-130#{index}"))}"
      end

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [Map.delete(@open_group, "operation_id")]
        })

      assert Enum.at(body["results"], 0)["code"] == "invalid_operation"
    end

    test "an unparseable occurred_on is rejected with invalid_operation" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [open_group_op(%{"occurred_on" => "2026-14-01"})]
        })

      assert Enum.at(body["results"], 0)["code"] == "invalid_operation"
    end

    test "a rejected operation does not stop later operations" do
      bad = %{"operation_id" => "op-x", "type" => "close_group", "group_id" => "group-81"}

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [bad, @open_group]
        })

      assert body == %{
               "results" => [
                 %{
                   "operation_id" => "op-x",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op()]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-2001",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      {group, 200} = api_get(build_conn(), "/api/v1/groups/group-81")
      assert group["data"]["deposit_paid_cents"] == 5_000
      assert group["data"]["outstanding_deposit_cents"] == 14_500
      assert group["data"]["revision"] == 2
    end

    test "rejects payments to a missing group" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"group_id" => "group-missing"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-2001",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "rejects unusable amounts with invalid_amount" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      for {amount, index} <- Enum.with_index([0, -100, 1.5]) do
        {body, 200} =
          api_post(build_conn(), "/api/v1/partner-batches", %{
            "operations" => [
              cash_payment_op(%{"operation_id" => "op-210#{index}", "amount_cents" => amount})
            ]
          })

        assert Enum.at(body["results"], 0)["code"] == "invalid_amount",
               "expected invalid_amount for #{inspect(amount)}"
      end
    end

    test "rejects payments exceeding the outstanding deposit" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"amount_cents" => 19_500})]
        })

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 1})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-2002",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }
    end
  end

  describe "reschedule_group" do
    test "moves the stay keeping its length" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [reschedule_op(%{"new_arrival_on" => "2026-12-20"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-3001",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      {group, 200} = api_get(build_conn(), "/api/v1/groups/group-81")
      assert group["data"]["arrival_on"] == "2026-12-20"
      assert group["data"]["departure_on"] == "2026-12-23"
    end

    test "increments revision even when arrival is unchanged" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [reschedule_op(%{"new_arrival_on" => "2026-12-10"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-3001",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-10",
               "new_departure_on" => "2026-12-13",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "revision" => 2
             }
    end

    test "rejects unusable new arrivals with invalid_stay" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      for {bad, index} <- Enum.with_index(["2026-10-03", "2026-10-02", "not-a-date"]) do
        {body, 200} =
          api_post(build_conn(), "/api/v1/partner-batches", %{
            "operations" => [
              reschedule_op(%{"operation_id" => "op-310#{index}", "new_arrival_on" => bad})
            ]
          })

        assert Enum.at(body["results"], 0)["code"] == "invalid_stay",
               "expected invalid_stay for #{inspect(bad)}"
      end
    end

    test "rejects reschedules against missing groups" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [reschedule_op(%{"group_id" => "group-missing"})]
        })

      assert Enum.at(body["results"], 0)["code"] == "group_not_found"
    end
  end

  describe "cancel_group" do
    test "refunds flexible reservations cancelled at least 14 days before arrival" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"amount_cents" => 10_000})]
        })

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cancel_op(%{"occurred_on" => "2026-11-26"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "retains cash for flexible reservations cancelled within 14 days" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"amount_cents" => 10_000})]
        })

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cancel_op(%{"occurred_on" => "2026-11-27"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "never refunds advance-purchase reservations" do
      op = open_group_op(%{"rate_plan" => "advance_purchase"})
      {_, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"amount_cents" => 20_000})]
        })

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cancel_op(%{"occurred_on" => "2026-10-10"})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 20_000,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "cancelling without cash just clears the unpaid deposit" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancel_op()]})

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 2
             }

      {group, 200} = api_get(build_conn(), "/api/v1/groups/group-81")
      assert group["data"]["status"] == "cancelled"
      assert group["data"]["deposit_due_cents"] == 0
      assert group["data"]["deposit_paid_cents"] == 0
      assert group["data"]["outstanding_deposit_cents"] == 0
    end

    test "later operations against a cancelled group are rejected with group_not_active" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancel_op()]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            cash_payment_op(),
            reschedule_op(),
            cancel_op(%{"operation_id" => "op-4002"})
          ]
        })

      for result <- body["results"] do
        assert result["status"] == "rejected"
        assert result["code"] == "group_not_active"
      end
    end
  end

  describe "revisions" do
    test "operations in one batch observe earlier operations" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            @open_group,
            cash_payment_op(%{"expected_revision" => 1}),
            cash_payment_op(%{
              "operation_id" => "op-2002",
              "amount_cents" => 2_000,
              "expected_revision" => 2
            })
          ]
        })

      assert body == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-2001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-2002",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 2_000,
                   "outstanding_deposit_cents" => 12_500,
                   "revision" => 3
                 }
               ]
             }
    end

    test "a stale revision is rejected before other domain rules" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            cash_payment_op(%{"expected_revision" => 2, "amount_cents" => 999_999})
          ]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-2001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 1
             }
    end

    test "a stale rejection leaves the group unchanged" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"expected_revision" => 99})]
        })

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            cash_payment_op(%{
              "operation_id" => "op-2002",
              "expected_revision" => 1,
              "amount_cents" => 1_000
            })
          ]
        })

      assert Enum.at(body["results"], 0)["status"] == "applied"
      assert Enum.at(body["results"], 0)["revision"] == 2
    end

    test "rejected operations never increment the revision" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cash_payment_op(%{"amount_cents" => 99_999})]
        })

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            cash_payment_op(%{"operation_id" => "op-2002", "expected_revision" => 1})
          ]
        })

      assert Enum.at(body["results"], 0)["revision"] == 2
    end

    test "group existence is resolved before the revision comparison" do
      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            cash_payment_op(%{"group_id" => "group-missing", "expected_revision" => 5})
          ]
        })

      assert Enum.at(body["results"], 0)["code"] == "group_not_found"
    end

    test "a stale revision on a cancelled group is reported before inactivity" do
      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [@open_group]})

      {_, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancel_op()]})

      {body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [cancel_op(%{"operation_id" => "op-4002", "expected_revision" => 1})]
        })

      assert Enum.at(body["results"], 0) == %{
               "operation_id" => "op-4002",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end
  end
end
