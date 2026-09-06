defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  defp open_operation(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp open_group!(conn, overrides \\ %{}) do
    result = submit_one(conn, open_operation(overrides))
    assert result["status"] == "applied"
    result
  end

  describe "batch envelope" do
    test "a body without an operations array is an invalid batch", %{conn: conn} do
      for payload <- [%{}, %{"operations" => "nope"}, %{"operations" => %{}}, []] do
        response =
          conn
          |> post_batch(payload)
          |> json_response(422)

        assert response == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "an empty operations array returns no results", %{conn: conn} do
      assert %{"results" => []} =
               conn
               |> post_batch(%{"operations" => []})
               |> json_response(200)
    end

    test "operations are processed in array order and returned in order", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(%{"operation_id" => "op-1", "group_id" => "group-1"}),
          open_operation(%{"operation_id" => "op-2", "group_id" => "group-2"})
        ])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-2"]
      assert Enum.all?(results, &(&1["status"] == "applied"))
    end

    test "an unknown operation type is rejected and does not stop later operations", %{
      conn: conn
    } do
      results =
        submit(conn, [
          %{"operation_id" => "op-x", "type" => "explode", "occurred_on" => "2026-10-03"},
          open_operation()
        ])

      assert [
               %{"operation_id" => "op-x", "status" => "rejected", "code" => "invalid_operation"},
               %{"operation_id" => "op-open", "status" => "applied"}
             ] = results
    end

    test "a non-object operation is rejected with invalid_operation", %{conn: conn} do
      result = submit_one(conn, "hello")

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end
  end

  describe "open_group" do
    test "applies and computes the flexible deposit per room", %{conn: conn} do
      assert submit_one(conn, open_operation()) == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
    end

    test "an advance_purchase group requires the full lodging amount", %{conn: conn} do
      result =
        submit_one(
          conn,
          open_operation(%{
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
          })
        )

      # 3 nights x 15000 = 45000
      assert result["status"] == "applied"
      assert result["deposit_due_cents"] == 45000
    end

    test "each room's deposit is calculated and rounded separately", %{conn: conn} do
      result =
        submit_one(
          conn,
          open_operation(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 13},
              %{"room_id" => "room-b", "nightly_rate_cents" => 13}
            ]
          })
        )

      # 20% of 13 cents is 2.6 cents, which rounds up to 3 per room.
      # Rounding the group total instead would give 5, not 6.
      assert result["status"] == "applied"
      assert result["deposit_due_cents"] == 6
    end

    test "a one-night stay is valid", %{conn: conn} do
      result =
        submit_one(
          conn,
          open_operation(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
          })
        )

      assert result["status"] == "applied"
      assert result["deposit_due_cents"] == 2000
    end

    test "group identifiers are unique, including within one batch", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(%{"operation_id" => "op-1"}),
          open_operation(%{"operation_id" => "op-2"})
        ])

      assert [
               %{"operation_id" => "op-1", "status" => "applied"},
               %{
                 "operation_id" => "op-2",
                 "status" => "rejected",
                 "code" => "group_already_exists",
                 "group_id" => "group-81"
               }
             ] = results

      result = submit_one(conn, open_operation(%{"operation_id" => "op-3"}))
      assert result["code"] == "group_already_exists"
    end

    test "rejects a stay without at least one night", %{conn: conn} do
      for {{arrival, departure}, n} <-
            Enum.with_index([
              {"2026-12-10", "2026-12-10"},
              {"2026-12-11", "2026-12-10"}
            ]) do
        result =
          submit_one(
            conn,
            open_operation(%{
              "operation_id" => "op-open-#{n}",
              "arrival_on" => arrival,
              "departure_on" => departure
            })
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects missing or malformed stay dates", %{conn: conn} do
      for {overrides, n} <-
            Enum.with_index([
              %{"arrival_on" => "not-a-date"},
              %{"departure_on" => "2026-13-01"},
              %{"arrival_on" => nil},
              %{"departure_on" => 20_261_210}
            ]) do
        result =
          submit_one(
            conn,
            open_operation(Map.put(overrides, "operation_id", "op-open-#{n}"))
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects unusable room lists", %{conn: conn} do
      for {rooms, n} <-
            Enum.with_index([
              nil,
              [],
              "room-a",
              [
                %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                %{"room_id" => "room-a", "nightly_rate_cents" => 1000}
              ],
              [%{"room_id" => "room-a", "nightly_rate_cents" => -1}],
              [%{"room_id" => "room-a"}],
              [%{"nightly_rate_cents" => 15000}],
              ["room-a"]
            ]) do
        result =
          submit_one(
            conn,
            open_operation(%{"operation_id" => "op-open-#{n}", "rooms" => rooms})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms"
      end
    end

    test "rejects unknown or missing rate plans", %{conn: conn} do
      for {rate_plan, n} <- Enum.with_index(["non_refundable", nil, 20]) do
        result =
          submit_one(
            conn,
            open_operation(%{"operation_id" => "op-open-#{n}", "rate_plan" => rate_plan})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rate_plan"
      end
    end

    test "rejects operations missing data needed to identify and apply them", %{conn: conn} do
      for {overrides, n} <-
            Enum.with_index([
              %{"group_id" => nil},
              %{"guest_id" => nil},
              %{"property_id" => nil},
              %{"occurred_on" => nil},
              %{"occurred_on" => "not-a-date"}
            ]) do
        result =
          submit_one(
            conn,
            open_operation(Map.put(overrides, "operation_id", "op-open-#{n}"))
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end

    test "a rejected open_group does not create the group", %{conn: conn} do
      result = submit_one(conn, open_operation(%{"rate_plan" => "bogus"}))
      assert result["status"] == "rejected"

      assert conn
             |> get(~p"/api/v1/groups/group-81")
             |> json_response(404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "record_cash_payment" do
    defp payment_operation(overrides \\ %{}) do
      Map.merge(
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 10000
        },
        overrides
      )
    end

    test "applies cash to the outstanding deposit of an active group", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(),
          payment_operation()
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10000,
                 "outstanding_deposit_cents" => 9500,
                 "revision" => 2
               }
             ] = results
    end

    test "a payment can cover the deposit exactly", %{conn: conn} do
      open_group!(conn)

      result = submit_one(conn, payment_operation(%{"amount_cents" => 19500}))

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 0
    end

    test "rejects a payment for a missing group", %{conn: conn} do
      result = submit_one(conn, payment_operation())

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-81"
             }
    end

    test "rejects an operation without a group_id as invalid", %{conn: conn} do
      result = submit_one(conn, payment_operation(%{"group_id" => nil}))

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end

    test "rejects unusable payment amounts", %{conn: conn} do
      open_group!(conn)

      for {amount, n} <- Enum.with_index([0, -500, nil, "10000", 100.5]) do
        result =
          submit_one(
            conn,
            payment_operation(%{"operation_id" => "op-pay-#{n}", "amount_cents" => amount})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end
    end

    test "rejects a payment above the outstanding deposit", %{conn: conn} do
      open_group!(conn)
      submit_one(conn, payment_operation(%{"amount_cents" => 10000}))

      result =
        submit_one(
          conn,
          payment_operation(%{"operation_id" => "op-pay-more", "amount_cents" => 9501})
        )

      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
    end

    test "rejects a payment for a cancelled group", %{conn: conn} do
      open_group!(conn)

      submit_one(conn, %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      })

      result = submit_one(conn, payment_operation())

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end
  end

  describe "reschedule_group" do
    defp reschedule_operation(overrides \\ %{}) do
      Map.merge(
        %{
          "operation_id" => "op-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20"
        },
        overrides
      )
    end

    test "moves the stay, shifting departure by the same number of days", %{conn: conn} do
      open_group!(conn)

      assert submit_one(conn, reschedule_operation()) == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

      assert group["arrival_on"] == "2026-12-20"
      assert group["departure_on"] == "2026-12-23"
      assert group["lodging_total_cents"] == 97500
      assert group["deposit_due_cents"] == 19500
    end

    test "rejects a new arrival that is not after the operation date", %{conn: conn} do
      open_group!(conn)

      for {new_arrival, n} <- Enum.with_index(["2026-12-01", "2026-11-30"]) do
        result =
          submit_one(
            conn,
            reschedule_operation(%{
              "operation_id" => "op-move-#{n}",
              "new_arrival_on" => new_arrival
            })
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects missing or malformed new arrival dates", %{conn: conn} do
      open_group!(conn)

      for {new_arrival, n} <- Enum.with_index([nil, "yesterday"]) do
        result =
          submit_one(
            conn,
            reschedule_operation(%{
              "operation_id" => "op-move-#{n}",
              "new_arrival_on" => new_arrival
            })
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects missing groups and inactive groups", %{conn: conn} do
      result = submit_one(conn, reschedule_operation())
      assert result["code"] == "group_not_found"

      open_group!(conn)

      submit_one(conn, %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      })

      result =
        submit_one(
          conn,
          reschedule_operation(%{"operation_id" => "op-move-late"})
        )

      assert result["code"] == "group_not_active"
    end
  end

  describe "cancel_group" do
    defp cancel_operation(overrides \\ %{}) do
      Map.merge(
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81"
        },
        overrides
      )
    end

    defp pay!(conn, amount_cents) do
      result =
        submit_one(conn, %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => amount_cents
        })

      assert result["status"] == "applied"
      result
    end

    test "refunds cash when a flexible group is cancelled at least 14 days before arrival", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, 10000)

      assert submit_one(conn, cancel_operation()) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "exactly 14 days before arrival is refundable", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      # arrival 2026-12-10 minus occurred_on 2026-11-26 is exactly 14 days
      result = submit_one(conn, cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert result["refunded_cents"] == 10000
      assert result["retained_cents"] == 0
    end

    test "retains cash when a flexible group is cancelled 13 days before arrival", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      result = submit_one(conn, cancel_operation(%{"occurred_on" => "2026-11-27"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10000
    end

    test "advance_purchase groups are always non-refundable", %{conn: conn} do
      open_group!(conn, %{
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      })

      pay!(conn, 45000)

      # 44 days before arrival: a flexible group would refund here
      result = submit_one(conn, cancel_operation(%{"occurred_on" => "2026-10-27"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 45000
    end

    test "unpaid deposit is simply no longer due", %{conn: conn} do
      open_group!(conn)

      result = submit_one(conn, cancel_operation())

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
    end

    test "the group becomes cancelled and later operations are rejected", %{conn: conn} do
      open_group!(conn)
      submit_one(conn, cancel_operation())

      for operation <- [
            cancel_operation(%{"operation_id" => "op-cancel-again"}),
            %{
              "operation_id" => "op-pay-late",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-11-27",
              "group_id" => "group-81",
              "amount_cents" => 100
            },
            %{
              "operation_id" => "op-move-late",
              "type" => "reschedule_group",
              "occurred_on" => "2026-11-27",
              "group_id" => "group-81",
              "new_arrival_on" => "2026-12-20"
            }
          ] do
        result = submit_one(conn, operation)

        assert result["status"] == "rejected"
        assert result["code"] == "group_not_active"
      end
    end

    test "rejects cancellation of a missing group", %{conn: conn} do
      result = submit_one(conn, cancel_operation())

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "cancellation uses the current arrival after a reschedule", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      submit_one(conn, %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      })

      # 2026-12-20 minus 2026-12-10 is 10 days: non-refundable
      result = submit_one(conn, cancel_operation(%{"occurred_on" => "2026-12-10"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10000
    end
  end

  describe "revisions" do
    test "each applied operation addressed to a group increments the revision once", %{conn: conn} do
      open_group!(conn)

      pay =
        submit_one(conn, %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 10000
        })

      move =
        submit_one(conn, %{
          "operation_id" => "op-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20"
        })

      cancel =
        submit_one(conn, %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-05",
          "group_id" => "group-81"
        })

      assert pay["revision"] == 2
      assert move["revision"] == 3
      assert cancel["revision"] == 4
    end

    test "an operation with a matching expected_revision is applied", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10000,
            "expected_revision" => 1
          }
        ])

      assert [%{"revision" => 1}, %{"status" => "applied", "revision" => 2}] = results
    end

    test "a stale revision is rejected with the revision fields and changes nothing", %{
      conn: conn
    } do
      open_group!(conn)

      submit_one(conn, %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10000
      })

      result =
        submit_one(conn, %{
          "operation_id" => "op-stale",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "expected_revision" => 1
        })

      assert result == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 10000
      assert group["status"] == "active"
    end

    test "stale revision is rejected before other domain validation", %{conn: conn} do
      open_group!(conn)

      # The amount is invalid AND the revision is stale: stale_revision wins.
      result =
        submit_one(conn, %{
          "operation_id" => "op-stale",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 99
        })

      assert result["code"] == "stale_revision"
    end

    test "group existence is resolved before revisions are compared", %{conn: conn} do
      result =
        submit_one(conn, %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-missing",
          "amount_cents" => 10000,
          "expected_revision" => 4
        })

      assert result["code"] == "group_not_found"
    end

    test "rejected operations do not increment the revision", %{conn: conn} do
      open_group!(conn)

      rejected =
        submit_one(conn, %{
          "operation_id" => "op-bad-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -1
        })

      assert rejected["status"] == "rejected"

      applied =
        submit_one(conn, %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 10000,
          "expected_revision" => 1
        })

      assert applied["status"] == "applied"
      assert applied["revision"] == 2
    end

    test "open_group does not use expected_revision", %{conn: conn} do
      result = submit_one(conn, open_operation(%{"expected_revision" => 99}))

      assert result["status"] == "applied"
      assert result["revision"] == 1
    end

    test "expected_revision observes changes made earlier in the same batch", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(),
          %{
            "operation_id" => "op-pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10000
          },
          %{
            "operation_id" => "op-pay-2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 1000,
            "expected_revision" => 1
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2}
             ] = results
    end
  end

  describe "batch failures" do
    test "a rejected operation does not undo earlier successful operations", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(),
          %{
            "operation_id" => "op-bad-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 99_999_999
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = results

      assert conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)
    end

    test "a rejected operation leaves the database exactly as it was", %{conn: conn} do
      open_group!(conn)

      result =
        submit_one(conn, %{
          "operation_id" => "op-bad-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -5
        })

      assert result["status"] == "rejected"

      group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end
  end

  describe "policy versions" do
    defp get_group(conn, group_id) do
      conn |> get(~p"/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
    end

    test "a flexible group booked before 2027-01-01 keeps the flex-14 policy", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-03"
      })

      data = get_group(conn, "group-81")

      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-01-18"
    end

    test "a flexible group booked on 2027-01-01 uses the flex-30 policy", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04"
      })

      data = get_group(conn, "group-81")

      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-01-30"
    end

    test "an advance_purchase group is advance-nonrefundable with no refundable date", %{
      conn: conn
    } do
      open_group!(conn, %{"occurred_on" => "2027-02-01", "rate_plan" => "advance_purchase"})

      data = get_group(conn, "group-81")

      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "flex-30 retains cash 29 days before arrival, where flex-14 would refund", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04"
      })

      submit_one(conn, %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-81",
        "amount_cents" => 9000
      })

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-31",
          "group_id" => "group-81"
        })

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 9000
    end

    test "flex-30 refunds when cancelling exactly on the refundable_until date", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04"
      })

      submit_one(conn, %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-81",
        "amount_cents" => 9000
      })

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-30",
          "group_id" => "group-81"
        })

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 9000
      assert result["retained_cents"] == 0
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-03"
      })

      result =
        submit_one(conn, %{
          "operation_id" => "op-move",
          "type" => "reschedule_group",
          "occurred_on" => "2027-06-01",
          "group_id" => "group-81",
          "new_arrival_on" => "2027-07-01"
        })

      assert result["status"] == "applied"
      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-06-17"

      data = get_group(conn, "group-81")

      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-06-17"
    end
  end

  describe "cancel_group with refund_method" do
    defp guest_credit(conn, guest_id, on) do
      conn
      |> get(~p"/api/v1/guests/#{guest_id}/credit?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")
    end

    defp ledger(conn, on) do
      conn
      |> get(~p"/api/v1/ledger?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")
    end

    test "a refundable cancellation with hotel_credit converts the cash to a 110% credit lot",
         %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      assert submit_one(conn, cancel_operation(%{"refund_method" => "hotel_credit"})) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11000,
               "revision" => 3
             }

      # the lot is available through 365 days after the cancellation
      assert guest_credit(conn, "guest-22", "2027-01-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 11000,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      # the original cash is neither refunded nor retained
      assert ledger(conn, "2027-01-01") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 11000,
               "credit_shortfall_cents" => 0
             }
    end

    test "the 10% credit bonus rounds an exact half-cent upward", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10005)

      # 10% of 10005 is 1000.5 cents, which rounds up to 1001
      result = submit_one(conn, cancel_operation(%{"refund_method" => "hotel_credit"}))

      assert result["credit_issued_cents"] == 11006
      assert guest_credit(conn, "guest-22", "2027-01-01")["available_cents"] == 11006
    end

    test "omitting refund_method keeps the cash refund behavior", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      result = submit_one(conn, cancel_operation())

      assert result["refunded_cents"] == 10000
      assert result["credit_issued_cents"] == 0
      assert guest_credit(conn, "guest-22", "2027-01-01")["available_cents"] == 0
      assert ledger(conn, "2027-01-01")["cash_converted_to_credit_cents"] == 0
    end

    test "hotel_credit is rejected when the cancellation is non-refundable", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      # 12 days before arrival: inside the 14-day window
      result =
        submit_one(
          conn,
          cancel_operation(%{"occurred_on" => "2026-11-28", "refund_method" => "hotel_credit"})
        )

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      # the group is left active and unchanged
      data = get_group(conn, "group-81")
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 10000

      assert ledger(conn, "2026-11-28")["cash_held_cents"] == 10000
    end

    test "hotel_credit is rejected for advance-purchase groups", %{conn: conn} do
      open_group!(conn, %{
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      })

      pay!(conn, 45000)

      # 53 days before arrival: a flexible group would refund here
      result =
        submit_one(
          conn,
          cancel_operation(%{"occurred_on" => "2026-10-18", "refund_method" => "hotel_credit"})
        )

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      assert get_group(conn, "group-81")["status"] == "active"
    end

    test "an unknown refund_method is rejected as an invalid operation", %{conn: conn} do
      open_group!(conn)

      for {refund_method, n} <- Enum.with_index(["voucher", "CASH", 0]) do
        result =
          submit_one(
            conn,
            cancel_operation(%{
              "operation_id" => "op-cancel-#{n}",
              "refund_method" => refund_method
            })
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "a refundable hotel_credit cancellation without cash issues no lot", %{conn: conn} do
      open_group!(conn)

      result = submit_one(conn, cancel_operation(%{"refund_method" => "hotel_credit"}))

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn, "guest-22", "2027-01-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger(conn, "2027-01-01")["cash_converted_to_credit_cents"] == 0
    end

    test "a stale revision is rejected before the refund method is evaluated", %{conn: conn} do
      open_group!(conn)
      pay!(conn, 10000)

      # non-refundable date, hotel_credit, AND a stale revision: stale_revision wins
      result =
        submit_one(
          conn,
          cancel_operation(%{
            "occurred_on" => "2026-11-28",
            "refund_method" => "hotel_credit",
            "expected_revision" => 99
          })
        )

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2
    end
  end

  describe "apply_hotel_credit" do
    defp pay!(conn, group_id, amount_cents) do
      result =
        submit_one(conn, %{
          "operation_id" => "op-pay-#{group_id}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        })

      assert result["status"] == "applied"
      result
    end

    # Issues a credit lot for guest-22 by opening a group, funding it with
    # cash, and cancelling it refundably with refund_method hotel_credit.
    defp issue_credit!(conn, group_id, cash_cents, occurred_on) do
      open_group!(conn, %{"group_id" => group_id, "operation_id" => "op-open-#{group_id}"})
      pay!(conn, group_id, cash_cents)

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel-#{group_id}",
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        })

      assert result["status"] == "applied"
      result
    end

    defp open_funded_target!(conn, overrides \\ %{}) do
      # 2 nights x 15000: deposit due is 20% of 30000 = 6000
      open_group!(
        conn,
        Map.merge(
          %{
            "operation_id" => "op-open-100",
            "group_id" => "group-100",
            "arrival_on" => "2027-01-10",
            "departure_on" => "2027-01-12",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
          },
          overrides
        )
      )
    end

    defp apply_credit_operation(overrides \\ %{}) do
      Map.merge(
        %{
          "operation_id" => "op-apply",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-100",
          "amount_cents" => 5000
        },
        overrides
      )
    end

    test "applies credit to the outstanding deposit of an active group", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)

      assert submit_one(conn, apply_credit_operation()) == %{
               "operation_id" => "op-apply",
               "status" => "applied",
               "group_id" => "group-100",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 1000,
               "revision" => 2
             }

      data = get_group(conn, "group-100")
      assert data["deposit_paid_cents"] == 5000
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 5000

      assert guest_credit(conn, "guest-22", "2026-12-01")["available_cents"] == 6000

      # applied credit is not cash, but stays in the credit liability
      assert ledger(conn, "2026-12-01") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 11000,
               "credit_shortfall_cents" => 0
             }
    end

    test "credit can cover the deposit exactly", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)

      result = submit_one(conn, apply_credit_operation(%{"amount_cents" => 6000}))

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 0
    end

    test "consumes lots by earliest expiry, then by source_operation_id", %{conn: conn} do
      # lot expiring first, and two lots with equal expiries
      issue_credit!(conn, "group-b", 5000, "2026-11-25")
      issue_credit!(conn, "group-c", 5000, "2026-11-25")
      issue_credit!(conn, "group-a", 5000, "2026-11-20")

      open_group!(conn, %{
        "operation_id" => "op-open-100",
        "group_id" => "group-100",
        "arrival_on" => "2027-01-10",
        "departure_on" => "2027-01-13"
      })

      # 19500 due; the lots are worth 5500 each
      result =
        submit_one(
          conn,
          apply_credit_operation(%{"amount_cents" => 5500 + 5500 + 1500})
        )

      assert result["status"] == "applied"

      # group-a (2027-11-20) is exhausted first; group-b (2027-11-25) next;
      # group-c has the same expiry as group-b but a later source operation
      assert guest_credit(conn, "guest-22", "2026-12-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 4000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-c",
                   "remaining_cents" => 4000,
                   "expires_on" => "2027-11-25"
                 }
               ]
             }
    end

    test "rejects when the guest cannot cover the amount with unexpired credit", %{conn: conn} do
      issue_credit!(conn, "group-81", 4000, "2026-11-26")
      open_funded_target!(conn)

      # 4400 available: one cent more cannot be covered
      result = submit_one(conn, apply_credit_operation(%{"amount_cents" => 4401}))

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "a guest without any credit cannot apply it", %{conn: conn} do
      open_funded_target!(conn)

      result = submit_one(conn, apply_credit_operation())

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "credit is only available to the guest it was issued to", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")

      # group-100 belongs to a different guest
      open_funded_target!(conn, %{"guest_id" => "guest-99"})

      result = submit_one(conn, apply_credit_operation())

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"

      # guest-22's credit is untouched
      assert guest_credit(conn, "guest-22", "2026-12-01")["available_cents"] == 11000
    end

    test "credit expiry is evaluated on the operation's occurred_on date", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)

      # the lot expires on 2027-11-26 and is available through that date
      applied =
        submit_one(
          conn,
          apply_credit_operation(%{"occurred_on" => "2027-11-26", "amount_cents" => 4000})
        )

      assert applied["status"] == "applied"

      open_group!(conn, %{
        "operation_id" => "op-open-200",
        "group_id" => "group-200",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-12",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      })

      # the following day the remaining credit has expired
      rejected =
        submit_one(
          conn,
          apply_credit_operation(%{
            "operation_id" => "op-apply-late",
            "group_id" => "group-200",
            "occurred_on" => "2027-11-27",
            "amount_cents" => 4000
          })
        )

      assert rejected["status"] == "rejected"
      assert rejected["code"] == "insufficient_credit"
    end

    test "rejects credit above the outstanding deposit before checking credit coverage", %{
      conn: conn
    } do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)

      # 11000 of credit is available, but only 6000 is outstanding
      result = submit_one(conn, apply_credit_operation(%{"amount_cents" => 6001}))

      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
    end

    test "rejects unusable amounts", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)

      for {amount, n} <- Enum.with_index([0, -500, nil, "5000", 100.5]) do
        result =
          submit_one(
            conn,
            apply_credit_operation(%{"operation_id" => "op-apply-#{n}", "amount_cents" => amount})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end
    end

    test "rejects missing, inactive, and unidentifiable groups", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")

      result =
        submit_one(
          conn,
          apply_credit_operation(%{
            "operation_id" => "op-apply-missing",
            "group_id" => "group-missing"
          })
        )

      assert result["code"] == "group_not_found"

      result =
        submit_one(
          conn,
          apply_credit_operation(%{"operation_id" => "op-apply-nil", "group_id" => nil})
        )

      assert result["code"] == "invalid_operation"

      result =
        submit_one(
          conn,
          apply_credit_operation(%{
            "operation_id" => "op-apply-cancelled",
            "group_id" => "group-81"
          })
        )

      assert result["code"] == "group_not_active"
    end

    test "rejects a malformed occurred_on as an invalid operation", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)

      for {occurred_on, n} <- Enum.with_index([nil, "yesterday"]) do
        result =
          submit_one(
            conn,
            apply_credit_operation(%{
              "operation_id" => "op-apply-#{n}",
              "occurred_on" => occurred_on
            })
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end

    test "a rejected attempt does not advance the revision", %{conn: conn} do
      open_funded_target!(conn)

      rejected = submit_one(conn, apply_credit_operation())
      assert rejected["code"] == "insufficient_credit"

      issue_credit!(conn, "group-81", 10000, "2026-11-26")

      applied =
        submit_one(
          conn,
          apply_credit_operation(%{
            "operation_id" => "op-apply-funded",
            "expected_revision" => 1
          })
        )

      assert applied["status"] == "applied"
      assert applied["revision"] == 2
    end

    test "a stale revision is rejected before credit coverage is checked", %{conn: conn} do
      open_funded_target!(conn)

      # no credit at all AND a stale revision: stale_revision wins
      result = submit_one(conn, apply_credit_operation(%{"expected_revision" => 99}))

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1
    end

    test "a refundable cancellation restores applied credit to its original lot", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)
      submit_one(conn, apply_credit_operation())

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel-100",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-20",
          "group_id" => "group-100"
        })

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # restored to the original lot with its original expiry, with no
      # second 10% bonus
      assert guest_credit(conn, "guest-22", "2026-12-20") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-81",
                   "remaining_cents" => 11000,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert ledger(conn, "2026-12-20")["credit_liability_cents"] == 11000
    end

    test "restored credit whose expiry has passed expires immediately", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")

      open_funded_target!(conn, %{
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-12"
      })

      submit_one(conn, apply_credit_operation(%{"occurred_on" => "2027-11-20"}))

      # refundable, but the lot expired on 2027-11-26, before the cancellation
      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel-100",
          "type" => "cancel_group",
          "occurred_on" => "2027-12-01",
          "group_id" => "group-100"
        })

      assert result["status"] == "applied"

      # the restored amount never becomes available again
      assert guest_credit(conn, "guest-22", "2027-12-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      # and it reduces the credit liability instead
      assert ledger(conn, "2027-12-01")["credit_liability_cents"] == 0
    end

    test "a non-refundable cancellation consumes the applied credit", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)
      submit_one(conn, apply_credit_operation())

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel-100",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-09",
          "group_id" => "group-100"
        })

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # the unapplied remainder of the lot is untouched
      assert guest_credit(conn, "guest-22", "2027-01-09")["available_cents"] == 6000
      assert ledger(conn, "2027-01-09")["credit_liability_cents"] == 6000

      data = get_group(conn, "group-100")
      assert data["status"] == "cancelled"
      # group totals describe active rooms only: a cancelled group has none
      assert data["credit_paid_cents"] == 0
    end

    test "settling a mixed cash and credit group with hotel_credit", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000, "2026-11-26")
      open_funded_target!(conn)
      pay!(conn, "group-100", 2000)
      submit_one(conn, apply_credit_operation(%{"amount_cents" => 3000}))

      # while the group is active, its cash is held and its credit stays in
      # the liability (8000 remaining on the lot + 3000 applied)
      assert ledger(conn, "2026-12-01") == %{
               "cash_held_cents" => 2000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 11000,
               "credit_shortfall_cents" => 0
             }

      data = get_group(conn, "group-100")
      assert data["cash_paid_cents"] == 2000
      assert data["credit_paid_cents"] == 3000
      assert data["outstanding_deposit_cents"] == 1000

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel-100",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-20",
          "group_id" => "group-100",
          "refund_method" => "hotel_credit"
        })

      # only the cash portion becomes a new lot with the 10% bonus
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 2200

      # the applied credit returns to its original lot without a second bonus
      assert guest_credit(conn, "guest-22", "2026-12-20") == %{
               "guest_id" => "guest-22",
               "available_cents" => 13200,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-81",
                   "remaining_cents" => 11000,
                   "expires_on" => "2027-11-26"
                 },
                 %{
                   "source_operation_id" => "op-cancel-100",
                   "remaining_cents" => 2200,
                   "expires_on" => "2027-12-20"
                 }
               ]
             }

      assert ledger(conn, "2026-12-20") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 12000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 13200,
               "credit_shortfall_cents" => 0
             }
    end
  end
end
