defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @group_path "/api/v1/groups"

  defp open_group_op(overrides \\ %{}) do
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

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp reschedule_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-15"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [open_group_op(overrides)])
    assert %{"status" => "applied"} = result
    {conn, result}
  end

  defp get_group(conn, group_id) do
    conn = get(conn, "#{@group_path}/#{group_id}")
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_credit(conn, guest_id, on \\ nil) do
    conn = get(conn, "/api/v1/guests/#{guest_id}/credit", if(on, do: %{"on" => on}, else: %{}))
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_ledger(conn, on \\ nil) do
    conn = get(conn, "/api/v1/ledger", if(on, do: %{"on" => on}, else: %{}))
    {conn, json_response(conn, 200)["data"]}
  end

  defp pay(conn, group_id, amount_cents, overrides \\ %{}) do
    {conn, [result]} =
      post_batch(conn, [
        payment_op(
          Map.merge(
            %{
              "operation_id" => "pay-#{group_id}",
              "group_id" => group_id,
              "amount_cents" => amount_cents
            },
            overrides
          )
        )
      ])

    assert result["status"] == "applied"
    conn
  end

  # Opens a group, funds it with cash, and cancels it into hotel credit so
  # the guest holds a credit lot worth 110% of the cash.
  defp issue_credit(conn, group_id, cash_cents, cancel_id, occurred_on \\ "2026-10-04") do
    {conn, _result} =
      open_group(conn, %{"operation_id" => "open-#{group_id}", "group_id" => group_id})

    conn = pay(conn, group_id, cash_cents)

    {conn, [result]} =
      post_batch(conn, [
        cancel_op(%{
          "operation_id" => cancel_id,
          "group_id" => group_id,
          "occurred_on" => occurred_on,
          "refund_method" => "hotel_credit"
        })
      ])

    assert result["status"] == "applied"
    {conn, result}
  end

  describe "POST /api/v1/partner-batches batch handling" do
    test "rejects a body without an operations array", %{conn: conn} do
      for body <- [%{}, %{"operations" => "not-a-list"}, %{"operations" => 3}, %{"other" => []}] do
        conn = post(conn, @batch_path, body)
        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "accepts an empty operations array", %{conn: conn} do
      {conn, results} = post_batch(conn, [])
      assert results == []
      _ = conn
    end

    test "returns one result per operation, in order", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1"}),
          %{"operation_id" => "op-2", "type" => "unknown_type"},
          payment_op(%{"operation_id" => "op-3"})
        ])

      assert [
               %{"operation_id" => "op-1", "status" => "applied"},
               %{"operation_id" => "op-2", "status" => "rejected", "code" => "invalid_operation"},
               %{"operation_id" => "op-3", "status" => "applied"}
             ] = results
    end

    test "a rejected operation does not undo earlier ones or stop later ones", %{conn: conn} do
      {conn, _results} =
        post_batch(conn, [
          open_group_op(),
          payment_op(%{"operation_id" => "bad", "amount_cents" => -1}),
          payment_op(%{"operation_id" => "good", "amount_cents" => 2000})
        ])

      {_conn, group} = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 2000
      assert group["outstanding_deposit_cents"] == 17500
      assert group["revision"] == 2
    end

    test "operations observe changes made by earlier operations in the batch", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1"}),
          payment_op(%{"operation_id" => "op-2", "expected_revision" => 1}),
          reschedule_op(%{"operation_id" => "op-3", "expected_revision" => 2}),
          cancel_op(%{"operation_id" => "op-4", "expected_revision" => 3})
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied)
      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    end
  end

  describe "invalid_operation rejections" do
    test "unknown, missing, or non-string operation types", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1", "type" => "close_group"}),
          open_group_op(%{"operation_id" => "op-2"}) |> Map.delete("type"),
          open_group_op(%{"operation_id" => "op-3", "type" => 42})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end
    end

    test "operations that are not objects", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, ["open_group"])

      assert result == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "missing identifiers and common fields", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1"}) |> Map.delete("group_id"),
          open_group_op(%{"operation_id" => "op-2"}) |> Map.delete("occurred_on"),
          open_group_op(%{"operation_id" => "op-3", "occurred_on" => "not-a-date"}),
          open_group_op(%{"operation_id" => "op-4"}) |> Map.delete("guest_id"),
          open_group_op(%{"operation_id" => "op-5"}) |> Map.delete("property_id"),
          payment_op(%{"operation_id" => "op-6"}) |> Map.delete("group_id")
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end
    end

    test "missing type-specific data", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1"}) |> Map.delete("rooms"),
          open_group_op(%{"operation_id" => "op-2"}) |> Map.delete("arrival_on"),
          open_group_op(%{"operation_id" => "op-3"}) |> Map.delete("rate_plan"),
          payment_op(%{"operation_id" => "op-4"}) |> Map.delete("amount_cents"),
          reschedule_op(%{"operation_id" => "op-5"}) |> Map.delete("new_arrival_on")
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end
    end

    test "an invalid operation leaves the database unchanged", %{conn: conn} do
      {conn, _results} =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-1",
            "group_id" => "group-bad",
            "arrival_on" => 42
          })
        ])

      conn = get(conn, "#{@group_path}/group-bad")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "open_group" do
    test "opens the group from the API example", %{conn: conn} do
      {conn, [result]} = post_batch(conn, [open_group_op(%{"operation_id" => "op-1001"})])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }

      {_conn, group} = get_group(conn, "group-81")

      assert group == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19500
             }
    end

    test "uses occurred_on as the booked_on date", %{conn: conn} do
      {conn, _result} = open_group(conn, %{"occurred_on" => "2026-08-26"})
      {_conn, group} = get_group(conn, "group-81")
      assert group["booked_on"] == "2026-08-26"
    end

    test "an advance_purchase room deposits its full lodging amount", %{conn: conn} do
      {_conn, [result]} =
        post_batch(conn, [
          open_group_op(%{
            "rate_plan" => "advance_purchase",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
            ]
          })
        ])

      assert result["deposit_due_cents"] == 97500
    end

    test "rounds each flexible room deposit to the nearest cent, half up", %{conn: conn} do
      {_conn, [result]} =
        post_batch(conn, [
          open_group_op(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "r-2", "nightly_rate_cents" => 10001},
              %{"room_id" => "r-4", "nightly_rate_cents" => 10002},
              %{"room_id" => "r-6", "nightly_rate_cents" => 10003},
              %{"room_id" => "r-8", "nightly_rate_cents" => 10004}
            ]
          })
        ])

      # 20% deposits: 2000.2 -> 2000, 2000.4 -> 2000, 2000.6 -> 2001, 2000.8 -> 2001
      assert result["deposit_due_cents"] == 8002
    end

    test "sums individually rounded room deposits rather than rounding the total", %{conn: conn} do
      {_conn, [result]} =
        post_batch(conn, [
          open_group_op(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 10001},
              %{"room_id" => "room-b", "nightly_rate_cents" => 10002}
            ]
          })
        ])

      # 2000.2 -> 2000 plus 2000.4 -> 2000, not 4000.6 -> 4001
      assert result["deposit_due_cents"] == 4000
    end

    test "rejects a duplicate group id without touching the existing group", %{conn: conn} do
      {conn, _result} = open_group(conn)
      {_conn, [result]} = post_batch(conn, [open_group_op(%{"operation_id" => "op-dup"})])

      assert result == %{
               "operation_id" => "op-dup",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "group-81"
             }

      {conn, group} = get_group(conn, "group-81")
      assert group["revision"] == 1
      _ = conn
    end

    test "rejects stays without at least one night", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-1",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          }),
          open_group_op(%{
            "operation_id" => "op-2",
            "group_id" => "group-82",
            "arrival_on" => "2026-12-13",
            "departure_on" => "2026-12-10"
          })
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_stay"} = result
      end
    end

    test "rejects unusable stay dates", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1", "arrival_on" => "not-a-date"}),
          open_group_op(%{
            "operation_id" => "op-2",
            "group_id" => "g-2",
            "departure_on" => 20_261_213
          }),
          open_group_op(%{
            "operation_id" => "op-3",
            "group_id" => "g-3",
            "arrival_on" => "2026-13-01"
          })
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_stay"} = result
      end
    end

    test "rejects room lists without at least one room or with duplicate room ids", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1", "rooms" => []}),
          open_group_op(%{
            "operation_id" => "op-2",
            "group_id" => "g-2",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
            ]
          })
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      end
    end

    test "rejects unusable rooms", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1", "rooms" => "room-a"}),
          open_group_op(%{
            "operation_id" => "op-2",
            "group_id" => "g-2",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 0}]
          }),
          open_group_op(%{
            "operation_id" => "op-3",
            "group_id" => "g-3",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -100}]
          }),
          open_group_op(%{
            "operation_id" => "op-4",
            "group_id" => "g-4",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}]
          }),
          open_group_op(%{
            "operation_id" => "op-5",
            "group_id" => "g-5",
            "rooms" => [%{"room_id" => "room-a"}]
          }),
          open_group_op(%{
            "operation_id" => "op-6",
            "group_id" => "g-6",
            "rooms" => [%{"nightly_rate_cents" => 15000}]
          }),
          open_group_op(%{
            "operation_id" => "op-7",
            "group_id" => "g-7",
            "rooms" => ["room-a"]
          })
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      end
    end

    test "rejects unknown rate plans", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, [open_group_op(%{"rate_plan" => "semi-flexible"})])
      assert %{"status" => "rejected", "code" => "invalid_rate_plan"} = result
    end

    test "domain rejections do not create the group", %{conn: conn} do
      {conn, _results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1", "rate_plan" => "nope"})
        ])

      conn = get(conn, "#{@group_path}/group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      {conn, _result} = open_group(conn)

      {conn, [result]} =
        post_batch(conn, [payment_op(%{"operation_id" => "op-pay", "amount_cents" => 5000})])

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             }

      {_conn, group} = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 14500
      assert group["revision"] == 2
    end

    test "accepts a payment that exactly covers the outstanding deposit", %{conn: conn} do
      {conn, _result} = open_group(conn)

      {_conn, [result]} =
        post_batch(conn, [payment_op(%{"amount_cents" => 19500})])

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 0
    end

    test "accumulates multiple payments", %{conn: conn} do
      {conn, _result} = open_group(conn)

      {conn, results} =
        post_batch(conn, [
          payment_op(%{"operation_id" => "p-1", "amount_cents" => 4000}),
          payment_op(%{"operation_id" => "p-2", "amount_cents" => 6000})
        ])

      assert Enum.map(results, & &1["outstanding_deposit_cents"]) == [15500, 9500]
      assert Enum.map(results, & &1["revision"]) == [2, 3]

      {_conn, group} = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 10000
    end

    test "rejects payments for a missing group", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, [payment_op(%{"group_id" => "nope"})])

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nope"
             }
    end

    test "rejects payments for a cancelled group", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [cancel_op()])
      {_conn, [result]} = post_batch(conn, [payment_op()])

      assert %{"status" => "rejected", "code" => "group_not_active"} = result
    end

    test "rejects amounts that are not usable as a payment", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, results} =
        post_batch(conn, [
          payment_op(%{"operation_id" => "a-1", "amount_cents" => 0}),
          payment_op(%{"operation_id" => "a-2", "amount_cents" => -100}),
          payment_op(%{"operation_id" => "a-3", "amount_cents" => "5000"}),
          payment_op(%{"operation_id" => "a-4", "amount_cents" => 50.5}),
          payment_op(%{"operation_id" => "a-5", "amount_cents" => nil})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_amount", "group_id" => "group-81"} =
                 result
      end
    end

    test "rejects payments above the outstanding deposit", %{conn: conn} do
      {conn, _} = open_group(conn)
      {_conn, [result]} = post_batch(conn, [payment_op(%{"amount_cents" => 19501})])

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = result
    end

    test "rejected payments leave the group unchanged", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 99999})])

      {_conn, group} = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19500
      assert group["revision"] == 1
    end
  end

  describe "reschedule_group" do
    test "shifts arrival and departure by the same number of days", %{conn: conn} do
      {conn, _} = open_group(conn)

      {conn, [result]} =
        post_batch(conn, [
          reschedule_op(%{"operation_id" => "op-move", "new_arrival_on" => "2026-12-15"})
        ])

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-15",
               "new_departure_on" => "2026-12-18",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-01",
               "revision" => 2
             }

      {_conn, group} = get_group(conn, "group-81")
      assert group["arrival_on"] == "2026-12-15"
      assert group["departure_on"] == "2026-12-18"
      assert group["lodging_total_cents"] == 97500
      assert group["deposit_due_cents"] == 19500
    end

    test "keeps the price unchanged when the stay length is preserved", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [reschedule_op(%{"new_arrival_on" => "2027-02-01"})])

      {_conn, group} = get_group(conn, "group-81")
      assert group["arrival_on"] == "2027-02-01"
      assert group["departure_on"] == "2027-02-04"
      assert group["lodging_total_cents"] == 97500
    end

    test "applies even when the dates do not change, incrementing the revision", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, [result]} =
        post_batch(conn, [reschedule_op(%{"new_arrival_on" => "2026-12-10"})])

      assert %{"status" => "applied", "revision" => 2} = result
      assert result["new_arrival_on"] == "2026-12-10"
      assert result["new_departure_on"] == "2026-12-13"
    end

    test "rejects a new arrival that is not after the operation date", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, results} =
        post_batch(conn, [
          reschedule_op(%{"operation_id" => "r-1", "new_arrival_on" => "2026-10-04"}),
          reschedule_op(%{"operation_id" => "r-2", "new_arrival_on" => "2026-10-01"})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_stay", "group_id" => "group-81"} =
                 result
      end
    end

    test "rejects an unusable new arrival date", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, [result]} =
        post_batch(conn, [reschedule_op(%{"new_arrival_on" => "someday"})])

      assert %{"status" => "rejected", "code" => "invalid_stay"} = result
    end

    test "rejects rescheduling a missing or inactive group", %{conn: conn} do
      {conn, _} = open_group(conn)

      {conn, [missing]} =
        post_batch(conn, [reschedule_op(%{"operation_id" => "r-1", "group_id" => "nope"})])

      assert %{"status" => "rejected", "code" => "group_not_found"} = missing

      {conn, [_]} = post_batch(conn, [cancel_op()])
      {_conn, [inactive]} = post_batch(conn, [reschedule_op(%{"operation_id" => "r-2"})])

      assert %{"status" => "rejected", "code" => "group_not_active"} = inactive
    end
  end

  describe "cancel_group" do
    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 8000})])

      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{"operation_id" => "op-cancel", "occurred_on" => "2026-11-26"})
        ])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 8000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
    end

    test "treats exactly 14 days before arrival as refundable", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 8000})])

      # arrival 2026-12-10 minus 14 days = 2026-11-26
      {_conn, [result]} = post_batch(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])
      assert result["refunded_cents"] == 8000
      assert result["retained_cents"] == 0
    end

    test "retains cash for a flexible group cancelled less than 14 days before arrival", %{
      conn: conn
    } do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 8000})])

      {_conn, [result]} = post_batch(conn, [cancel_op(%{"occurred_on" => "2026-11-27"})])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 8000
    end

    test "advance_purchase cancellations are never refundable", %{conn: conn} do
      {conn, _} = open_group(conn, %{"rate_plan" => "advance_purchase"})
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 8000})])

      {_conn, [result]} = post_batch(conn, [cancel_op(%{"occurred_on" => "2026-10-04"})])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 8000
    end

    test "cancelling without payments settles nothing", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [result]} = post_batch(conn, [cancel_op()])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      assert group["deposit_paid_cents"] == 0
    end

    test "later operations on a cancelled group are rejected", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [cancel_op()])

      {_conn, results} =
        post_batch(conn, [
          payment_op(%{"operation_id" => "after-1"}),
          reschedule_op(%{"operation_id" => "after-2"}),
          cancel_op(%{"operation_id" => "after-3"})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "group_not_active"} = result
      end
    end

    test "cancelling a missing group is rejected", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, [cancel_op(%{"group_id" => "nope"})])
      assert %{"status" => "rejected", "code" => "group_not_found"} = result
    end
  end

  describe "expected_revision" do
    test "applies when the expected revision matches", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, [result]} =
        post_batch(conn, [payment_op(%{"amount_cents" => 1000, "expected_revision" => 1})])

      assert %{"status" => "applied", "revision" => 2} = result
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 1000})])

      {_conn, [result]} =
        post_batch(conn, [
          payment_op(%{
            "operation_id" => "stale",
            "amount_cents" => -5,
            "expected_revision" => 1
          })
        ])

      assert result == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "rejects a stale revision before the active-status check", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [cancel_op()])

      {_conn, [result]} =
        post_batch(conn, [payment_op(%{"expected_revision" => 1})])

      assert %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2} =
               result
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      {_conn, [result]} =
        post_batch(conn, [payment_op(%{"group_id" => "missing", "expected_revision" => 1})])

      assert %{"status" => "rejected", "code" => "group_not_found"} = result
    end

    test "a stale rejection leaves the group and ledger unchanged", %{conn: conn} do
      {conn, _} = open_group(conn)
      {conn, [_]} = post_batch(conn, [payment_op(%{"amount_cents" => 1000})])

      ledger_before = json_response(get(conn, "/api/v1/ledger"), 200)["data"]

      {conn, [_]} =
        post_batch(conn, [payment_op(%{"amount_cents" => 2000, "expected_revision" => 1})])

      {conn, group} = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 1000
      assert group["outstanding_deposit_cents"] == 18500
      assert group["revision"] == 2

      ledger_after = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger_before == ledger_after
      _ = conn
    end

    test "observes revisions created earlier in the same batch", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1"}),
          payment_op(%{"operation_id" => "op-2", "expected_revision" => 1}),
          payment_op(%{"operation_id" => "op-3", "expected_revision" => 1})
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied rejected)
      assert Enum.at(results, 2)["code"] == "stale_revision"
      assert Enum.at(results, 2)["actual_revision"] == 2
    end

    test "is optional and unused by open_group", %{conn: conn} do
      {_conn, [result]} =
        post_batch(conn, [open_group_op(%{"expected_revision" => 99})])

      assert %{"status" => "applied", "revision" => 1} = result
    end

    test "rejections never increment the revision", %{conn: conn} do
      {conn, _} = open_group(conn)

      {conn, _results} =
        post_batch(conn, [
          payment_op(%{"operation_id" => "r-1", "amount_cents" => 0}),
          payment_op(%{"operation_id" => "r-2", "amount_cents" => 99999}),
          payment_op(%{"operation_id" => "r-3", "expected_revision" => 5}),
          reschedule_op(%{"operation_id" => "r-4", "new_arrival_on" => "2020-01-01"}),
          cancel_op(%{"operation_id" => "r-5", "group_id" => "missing"})
        ])

      {_conn, group} = get_group(conn, "group-81")
      assert group["revision"] == 1
    end
  end

  describe "policy versions" do
    test "flexible groups booked before 2027 keep the 14-day window", %{conn: conn} do
      {conn, _result} = open_group(conn, %{"occurred_on" => "2026-12-31"})
      {_conn, group} = get_group(conn, "group-81")

      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2026-11-26"
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window", %{conn: conn} do
      {conn, _result} =
        open_group(conn, %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        })

      {_conn, group} = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-02-13"
    end

    test "advance purchase groups report the non-refundable policy", %{conn: conn} do
      {conn, _result} = open_group(conn, %{"rate_plan" => "advance_purchase"})
      {_conn, group} = get_group(conn, "group-81")

      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "a flex-30 cancellation is refundable exactly 30 days before arrival", %{conn: conn} do
      {conn, _} =
        open_group(conn, %{
          "operation_id" => "open-g-30",
          "group_id" => "g-30",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        })

      conn = pay(conn, "g-30", 4000)

      # arrival 2027-03-15 minus 30 days = 2027-02-13
      {_conn, [result]} =
        post_batch(conn, [cancel_op(%{"group_id" => "g-30", "occurred_on" => "2027-02-13"})])

      assert result["refunded_cents"] == 4000
      assert result["retained_cents"] == 0
    end

    test "a flex-30 cancellation 29 days before arrival is non-refundable", %{conn: conn} do
      {conn, _} =
        open_group(conn, %{
          "operation_id" => "open-g-29",
          "group_id" => "g-29",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        })

      conn = pay(conn, "g-29", 4000)

      {_conn, [result]} =
        post_batch(conn, [cancel_op(%{"group_id" => "g-29", "occurred_on" => "2027-02-14"})])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 4000
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      {conn, _} = open_group(conn)

      {conn, [result]} =
        post_batch(conn, [reschedule_op(%{"new_arrival_on" => "2027-06-01"})])

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-05-18"

      {_conn, group} = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-05-18"
    end

    test "rescheduling an advance purchase group reports its fixed policy", %{conn: conn} do
      {conn, _} = open_group(conn, %{"rate_plan" => "advance_purchase"})

      {_conn, [result]} =
        post_batch(conn, [reschedule_op(%{"new_arrival_on" => "2026-12-15"})])

      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  describe "cancel_group refund_method" do
    test "a refundable hotel-credit cancellation issues a 110% credit lot", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "group-81", 8000)

      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{
            "operation_id" => "cancel-17",
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result == %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 8800,
               "revision" => 3
             }

      {conn, ledger} = get_ledger(conn, "2026-10-04")
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_converted_to_credit_cents"] == 8000
      assert ledger["credit_liability_cents"] == 8800

      expires_on = Date.add(~D[2026-10-04], 366) |> Date.to_string()

      {_conn, credit} = get_credit(conn, "guest-22", "2026-10-04")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 8800,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 8800,
                   "expires_on" => expires_on
                 }
               ]
             }
    end

    test "the 10% bonus rounds to the nearest cent, half up", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "group-81", 10005)

      {_conn, [result]} =
        post_batch(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])

      # bonus: 10% of 10005 = 1000.5 -> 1001
      assert result["credit_issued_cents"] == 11006
    end

    test "hotel credit is rejected for a non-refundable flexible cancellation", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "group-81", 8000)

      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-81"
             }

      {conn, group} = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 8000
      assert ledger["cash_converted_to_credit_cents"] == 0

      {conn, credit} = get_credit(conn, "guest-22")
      assert credit["available_cents"] == 0

      # the group can still be cancelled afterwards
      {_conn, [cancel_result]} =
        post_batch(conn, [
          cancel_op(%{"operation_id" => "op-cancel-2", "occurred_on" => "2026-11-27"})
        ])

      assert cancel_result["status"] == "applied"
      assert cancel_result["retained_cents"] == 8000
    end

    test "hotel credit is rejected for an advance purchase cancellation", %{conn: conn} do
      {conn, _} = open_group(conn, %{"rate_plan" => "advance_purchase"})
      conn = pay(conn, "group-81", 8000)

      {conn, [result]} =
        post_batch(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = result

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "active"
    end

    test "an explicit cash refund method behaves like the default", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "group-81", 8000)

      {conn, [result]} =
        post_batch(conn, [cancel_op(%{"refund_method" => "cash"})])

      assert result["refunded_cents"] == 8000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      {_conn, credit} = get_credit(conn, "guest-22")
      assert credit["available_cents"] == 0
    end

    test "unknown refund methods are invalid operations", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, results} =
        post_batch(conn, [
          cancel_op(%{"operation_id" => "c-1", "refund_method" => "voucher"}),
          cancel_op(%{"operation_id" => "c-2", "refund_method" => 3}),
          cancel_op(%{"operation_id" => "c-3", "refund_method" => true})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end
    end

    test "a hotel-credit cancellation without cash issues no credit", %{conn: conn} do
      {conn, _} = open_group(conn)

      {conn, [result]} =
        post_batch(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])

      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 0

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["credit_liability_cents"] == 0

      {_conn, credit} = get_credit(conn, "guest-22")
      assert credit["lots"] == []
    end

    test "the issued lot is available for 365 days and expires the next day", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "group-81", 8000)

      {conn, [_]} =
        post_batch(conn, [
          cancel_op(%{"occurred_on" => "2026-10-04", "refund_method" => "hotel_credit"})
        ])

      {conn, available} = get_credit(conn, "guest-22", "2027-10-04")
      assert available["available_cents"] == 8800

      {_conn, expired} = get_credit(conn, "guest-22", "2027-10-05")
      assert expired["available_cents"] == 0
      assert expired["lots"] == []
    end
  end

  describe "apply_hotel_credit" do
    test "applies credit to the outstanding deposit", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-17")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})

      {conn, ledger_before} = get_ledger(conn, "2026-10-05")

      {conn, [result]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 5000})])

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-82",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             }

      {conn, group} = get_group(conn, "group-82")
      assert group["deposit_paid_cents"] == 5000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 14500

      {conn, credit} = get_credit(conn, "guest-22", "2026-10-05")
      assert credit["available_cents"] == 3800

      {conn, ledger_after} = get_ledger(conn, "2026-10-05")
      assert ledger_before["credit_liability_cents"] == 8800
      assert ledger_after["credit_liability_cents"] == 8800
      assert ledger_after["cash_held_cents"] == 0
      _ = conn
    end

    test "credit cannot exceed the outstanding deposit", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 18000, "cancel-17")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})

      {conn, [rejected]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 19501})])

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = rejected

      {conn, [applied]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 19500})])

      assert applied["status"] == "applied"
      assert applied["outstanding_deposit_cents"] == 0

      {_conn, group} = get_group(conn, "group-82")
      assert group["revision"] == 2
    end

    test "consumes lots by earliest expiry, then by source operation id", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 2000, "cancel-b", "2026-10-04")
      {conn, _} = issue_credit(conn, "group-b", 2000, "cancel-a", "2026-10-10")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-c", "group_id" => "group-c"})

      {conn, [result]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-c", "amount_cents" => 3000})])

      assert result["status"] == "applied"

      # The earlier lot (cancel-b, expires 2027-10-05) is consumed first.
      {_conn, credit} = get_credit(conn, "guest-22", "2026-10-05")

      assert credit["available_cents"] == 1400

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 1400,
                 "expires_on" => "2027-10-11"
               }
             ]
    end

    test "uses source operation order for equal expiries", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 2000, "cancel-b", "2026-10-04")
      {conn, _} = issue_credit(conn, "group-b", 2000, "cancel-a", "2026-10-04")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-c", "group_id" => "group-c"})

      {conn, [_]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-c", "amount_cents" => 1000})])

      {_conn, credit} = get_credit(conn, "guest-22", "2026-10-05")

      assert credit["available_cents"] == 3400

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 1200,
                 "expires_on" => "2027-10-05"
               },
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-10-05"
               }
             ]
    end

    test "rejects amounts the guest cannot cover", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 2000, "cancel-17")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})

      {conn, [result]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 2201})])

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "insufficient_credit",
               "group_id" => "group-82"
             }

      {conn, group} = get_group(conn, "group-82")
      assert group["revision"] == 1

      {_conn, credit} = get_credit(conn, "guest-22", "2026-10-05")
      assert credit["available_cents"] == 2200
    end

    test "rejects a guest without any credit", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, [result]} = post_batch(conn, [credit_op(%{"amount_cents" => 100})])

      assert %{"status" => "rejected", "code" => "insufficient_credit"} = result
    end

    test "rejects amounts that are not usable as a payment", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-17")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})

      {_conn, results} =
        post_batch(conn, [
          credit_op(%{"operation_id" => "a-1", "group_id" => "group-82", "amount_cents" => 0}),
          credit_op(%{"operation_id" => "a-2", "group_id" => "group-82", "amount_cents" => -100}),
          credit_op(%{
            "operation_id" => "a-3",
            "group_id" => "group-82",
            "amount_cents" => "5000"
          }),
          credit_op(%{"operation_id" => "a-4", "group_id" => "group-82", "amount_cents" => 50.5}),
          credit_op(%{"operation_id" => "a-5", "group_id" => "group-82", "amount_cents" => nil})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_amount", "group_id" => "group-82"} =
                 result
      end
    end

    test "rejects credit for a missing or inactive group", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-17")

      {conn, [missing]} =
        post_batch(conn, [credit_op(%{"operation_id" => "c-1", "group_id" => "nope"})])

      assert %{"status" => "rejected", "code" => "group_not_found"} = missing

      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})
      {conn, [_]} = post_batch(conn, [cancel_op(%{"group_id" => "group-82"})])

      {_conn, [inactive]} =
        post_batch(conn, [credit_op(%{"operation_id" => "c-2", "group_id" => "group-82"})])

      assert %{"status" => "rejected", "code" => "group_not_active"} = inactive
    end

    test "rejects a stale revision before the credit rules", %{conn: conn} do
      {conn, _} = open_group(conn)

      {_conn, [result]} =
        post_batch(conn, [
          credit_op(%{"amount_cents" => 999_999, "expected_revision" => 5})
        ])

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }
    end

    test "evaluates lot expiry using the operation date", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 2000, "cancel-17", "2026-10-04")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-83", "group_id" => "group-83"})

      # lot expires 2027-10-05: usable on the day before, expired on the day
      {conn, [applied]} =
        post_batch(conn, [
          credit_op(%{
            "group_id" => "group-82",
            "amount_cents" => 1000,
            "occurred_on" => "2027-10-04"
          })
        ])

      assert applied["status"] == "applied"

      {_conn, [expired]} =
        post_batch(conn, [
          credit_op(%{
            "operation_id" => "op-credit-2",
            "group_id" => "group-83",
            "amount_cents" => 1000,
            "occurred_on" => "2027-10-05"
          })
        ])

      assert %{"status" => "rejected", "code" => "insufficient_credit"} = expired
    end

    test "missing amount_cents is an invalid operation", %{conn: conn} do
      {_conn, [result]} =
        post_batch(conn, [credit_op() |> Map.delete("amount_cents")])

      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "credit issued earlier in the same batch can be applied", %{conn: conn} do
      {_conn, results} =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-1", "group_id" => "group-a"}),
          payment_op(%{
            "operation_id" => "op-2",
            "group_id" => "group-a",
            "amount_cents" => 8000
          }),
          cancel_op(%{
            "operation_id" => "cancel-17",
            "group_id" => "group-a",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "op-4", "group_id" => "group-b"}),
          credit_op(%{"operation_id" => "op-5", "group_id" => "group-b", "amount_cents" => 8800})
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied applied)
      assert Enum.at(results, 2)["credit_issued_cents"] == 8800
      assert Enum.at(results, 4)["outstanding_deposit_cents"] == 10700
    end
  end

  describe "settling groups funded by credit" do
    test "a refundable cancellation restores applied credit to its original lot", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-17")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})
      conn = pay(conn, "group-82", 4000)

      {conn, [_]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 5000})])

      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{
            "operation_id" => "settle",
            "group_id" => "group-82",
            "occurred_on" => "2026-10-06"
          })
        ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 4000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      {conn, credit} = get_credit(conn, "guest-22", "2026-10-06")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 8800,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 8800,
                   "expires_on" => "2027-10-05"
                 }
               ]
             }

      {_conn, ledger} = get_ledger(conn, "2026-10-06")
      assert ledger["credit_liability_cents"] == 8800
    end

    test "mixed funding converts cash with a bonus and restores credit without one", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-a")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})
      conn = pay(conn, "group-82", 4000)

      {conn, [_]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 3000})])

      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{
            "operation_id" => "cancel-b",
            "group_id" => "group-82",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 4400

      {conn, credit} = get_credit(conn, "guest-22", "2026-11-01")
      assert credit["available_cents"] == 13200

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 8800,
                 "expires_on" => "2027-10-05"
               },
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 4400,
                 "expires_on" => "2027-11-02"
               }
             ]

      {_conn, ledger} = get_ledger(conn, "2026-11-01")
      assert ledger["cash_converted_to_credit_cents"] == 12000
      assert ledger["credit_liability_cents"] == 13200
    end

    test "credit restored after its expiry expires immediately", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-17")

      {conn, _} =
        open_group(conn, %{
          "operation_id" => "open-group-82",
          "group_id" => "group-82",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-13"
        })

      {conn, [_]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 5000})])

      # cancelled refundably, but after the lot's 2027-10-05 expiry
      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{
            "operation_id" => "settle",
            "group_id" => "group-82",
            "occurred_on" => "2027-10-06"
          })
        ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0

      {conn, credit} = get_credit(conn, "guest-22", "2027-10-06")
      assert credit["available_cents"] == 0
      assert credit["lots"] == []

      conn = get(conn, "/api/v1/ledger", %{"on" => "2027-10-04"})
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 8800

      conn = get(conn, "/api/v1/ledger", %{"on" => "2027-10-06"})
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
      _ = conn
    end

    test "a non-refundable cancellation consumes applied credit", %{conn: conn} do
      {conn, _} = issue_credit(conn, "group-a", 8000, "cancel-17")
      {conn, _} = open_group(conn, %{"operation_id" => "open-group-82", "group_id" => "group-82"})
      conn = pay(conn, "group-82", 4000)

      {conn, [_]} =
        post_batch(conn, [credit_op(%{"group_id" => "group-82", "amount_cents" => 3000})])

      {conn, [result]} =
        post_batch(conn, [
          cancel_op(%{
            "operation_id" => "settle",
            "group_id" => "group-82",
            "occurred_on" => "2026-11-27"
          })
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 4000
      assert result["credit_issued_cents"] == 0

      {conn, credit} = get_credit(conn, "guest-22", "2026-11-27")
      assert credit["available_cents"] == 5800

      {_conn, ledger} = get_ledger(conn, "2026-11-27")
      assert ledger["cash_retained_cents"] == 4000
      assert ledger["credit_liability_cents"] == 5800
    end
  end
end
