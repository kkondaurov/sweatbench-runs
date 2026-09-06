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
      for {arrival, departure} <- [
            {"2026-12-10", "2026-12-10"},
            {"2026-12-11", "2026-12-10"}
          ] do
        result =
          submit_one(
            conn,
            open_operation(%{"arrival_on" => arrival, "departure_on" => departure})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects missing or malformed stay dates", %{conn: conn} do
      for overrides <- [
            %{"arrival_on" => "not-a-date"},
            %{"departure_on" => "2026-13-01"},
            %{"arrival_on" => nil},
            %{"departure_on" => 20_261_210}
          ] do
        result = submit_one(conn, open_operation(overrides))

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects unusable room lists", %{conn: conn} do
      for rooms <- [
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
          ] do
        result = submit_one(conn, open_operation(%{"rooms" => rooms}))

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms"
      end
    end

    test "rejects unknown or missing rate plans", %{conn: conn} do
      for rate_plan <- ["non_refundable", nil, 20] do
        result = submit_one(conn, open_operation(%{"rate_plan" => rate_plan}))

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rate_plan"
      end
    end

    test "rejects operations missing data needed to identify and apply them", %{conn: conn} do
      for overrides <- [
            %{"group_id" => nil},
            %{"guest_id" => nil},
            %{"property_id" => nil},
            %{"occurred_on" => nil},
            %{"occurred_on" => "not-a-date"}
          ] do
        result = submit_one(conn, open_operation(overrides))

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

      for amount <- [0, -500, nil, "10000", 100.5] do
        result = submit_one(conn, payment_operation(%{"amount_cents" => amount}))

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end
    end

    test "rejects a payment above the outstanding deposit", %{conn: conn} do
      open_group!(conn)
      submit_one(conn, payment_operation(%{"amount_cents" => 10000}))

      result = submit_one(conn, payment_operation(%{"amount_cents" => 9501}))

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

      for new_arrival <- ["2026-12-01", "2026-11-30"] do
        result = submit_one(conn, reschedule_operation(%{"new_arrival_on" => new_arrival}))

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects missing or malformed new arrival dates", %{conn: conn} do
      open_group!(conn)

      for new_arrival <- [nil, "yesterday"] do
        result = submit_one(conn, reschedule_operation(%{"new_arrival_on" => new_arrival}))

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

      result = submit_one(conn, reschedule_operation(%{"occurred_on" => "2026-12-01"}))
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
end
