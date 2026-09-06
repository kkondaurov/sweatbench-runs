defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  alias GroupStay.Groups
  alias GroupStay.Ledger

  describe "batch envelope" do
    test "returns one result per operation in order", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(%{"operation_id" => "op-1"}),
          open_group_op(%{"operation_id" => "op-2", "group_id" => "group-82"}),
          cancel_group_op(%{"operation_id" => "op-3", "group_id" => "group-82"})
        ])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-2", "op-3"]
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]
    end

    test "an empty operations array is a valid batch", %{conn: conn} do
      conn
      |> post(~p"/api/v1/partner-batches", %{operations: []})
      |> json_response(200)
      |> then(fn body -> assert body == %{"results" => []} end)
    end

    test "a body without an operations array is rejected as invalid_batch" do
      for body <- [%{}, %{"operations" => "nope"}, %{"operations" => %{}}, %{"operations" => nil}] do
        response =
          fresh_conn()
          |> post(~p"/api/v1/partner-batches", body)
          |> json_response(422)

        assert response == %{"error" => %{"code" => "invalid_batch"}}
      end

      # JSON bodies that decode to something other than an object are also invalid.
      for raw_body <- [~s([1, 2, 3]), ~s("hello")] do
        response =
          fresh_conn()
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/v1/partner-batches", raw_body)
          |> json_response(422)

        assert response == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "a rejected operation does not undo earlier operations or stop later ones", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(%{"operation_id" => "op-1"}),
          record_cash_payment_op(%{"operation_id" => "op-2", "amount_cents" => -5}),
          record_cash_payment_op(%{"operation_id" => "op-3", "amount_cents" => 7_000})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "applied", "outstanding_deposit_cents" => 12_500}
             ] = results

      group = get_group!(fresh_conn(), "group-81")
      assert group["deposit_paid_cents"] == 7_000
    end
  end

  describe "open_group" do
    test "applies and reports the deposit due from the API example", %{conn: conn} do
      [result] = post_batch!(conn, [open_group_op()])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end

    test "records booked_on from occurred_on and computes totals", %{conn: conn} do
      open_group!(conn)

      group = get_group!(fresh_conn(), "group-81")
      assert group["booked_on"] == "2026-10-03"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500
    end

    test "advance_purchase rooms require their full lodging as deposit", %{conn: conn} do
      open_group!(conn, %{"rate_plan" => "advance_purchase"})

      group = get_group!(fresh_conn(), "group-81")
      assert group["deposit_due_cents"] == 97_500
    end

    test "flexible deposits are rounded per room before summing", %{conn: conn} do
      # Room lodgings of 101 and 102 cents: rounding each room's 20% separately
      # yields 20 + 20 = 40, while rounding the summed lodging would yield 41.
      open_group!(conn, %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 101},
          %{"room_id" => "room-b", "nightly_rate_cents" => 102}
        ]
      })

      group = get_group!(fresh_conn(), "group-81")
      assert group["lodging_total_cents"] == 203
      assert group["deposit_due_cents"] == 40
    end

    test "rejects a duplicate group identifier without creating anything", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(%{"operation_id" => "op-1"}),
          open_group_op(%{"operation_id" => "op-2"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "rejected", "code" => code}] = results
      assert code == "group_already_exists"

      group = Groups.get_group("group-81")
      assert group.revision == 1
    end

    test "rejects stays without at least one night" do
      for {{arrival, departure}, index} <-
            Enum.with_index([{"2026-12-10", "2026-12-10"}, {"2026-12-10", "2026-12-09"}]) do
        [result] =
          post_batch!(fresh_conn(), [
            open_group_op(%{
              "operation_id" => "op-stay-#{index}",
              "arrival_on" => arrival,
              "departure_on" => departure
            })
          ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end

      assert Groups.get_group("group-81") == nil
    end

    test "rejects unusable stay dates" do
      for {overrides, index} <-
            Enum.with_index([
              %{"arrival_on" => "not-a-date"},
              %{"departure_on" => "2026-13-01"},
              %{"arrival_on" => 20_261_210}
            ]) do
        [result] =
          post_batch!(fresh_conn(), [
            open_group_op(Map.merge(%{"operation_id" => "op-date-#{index}"}, overrides))
          ])

        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects unusable room lists" do
      for {rooms, index} <-
            Enum.with_index([
              [],
              "not-a-list",
              [
                %{"room_id" => "room-a", "nightly_rate_cents" => 100},
                %{"room_id" => "room-a", "nightly_rate_cents" => 200}
              ],
              [%{"room_id" => "room-a"}],
              [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
              [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
              [%{"room_id" => "room-a", "nightly_rate_cents" => "100"}],
              ["room-a"]
            ]) do
        [result] =
          post_batch!(fresh_conn(), [
            open_group_op(%{"operation_id" => "op-rooms-#{index}", "rooms" => rooms})
          ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms", "rooms=#{inspect(rooms)}"
      end

      assert Groups.get_group("group-81") == nil
    end

    test "rejects unknown rate plans", %{conn: conn} do
      [result] = post_batch!(conn, [open_group_op(%{"rate_plan" => "semi_flexible"})])
      assert result["code"] == "invalid_rate_plan"
      assert Groups.get_group("group-81") == nil
    end

    test "rejects operations missing data needed to apply them" do
      for {operation, index} <-
            Enum.with_index([
              open_group_op() |> Map.delete("group_id"),
              open_group_op() |> Map.delete("guest_id"),
              open_group_op() |> Map.delete("property_id"),
              open_group_op() |> Map.delete("occurred_on"),
              open_group_op() |> Map.delete("arrival_on"),
              open_group_op() |> Map.delete("departure_on"),
              open_group_op() |> Map.delete("rate_plan"),
              open_group_op() |> Map.delete("rooms"),
              open_group_op() |> Map.delete("operation_id"),
              open_group_op() |> Map.delete("type"),
              open_group_op() |> Map.put("type", "hold_group"),
              open_group_op() |> Map.put("occurred_on", "10/03/2026"),
              "not even an operation"
            ]) do
        # Each distinct operation gets its own identifier; the variant with
        # no operation_id keeps testing that case.
        operation =
          if is_map(operation) and Map.has_key?(operation, "operation_id") do
            Map.put(operation, "operation_id", "op-invalid-#{index}")
          else
            operation
          end

        [result] = post_batch!(fresh_conn(), [operation])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation", "operation=#{inspect(operation)}"
      end

      assert Groups.get_group("group-81") == nil
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 10_000}),
          record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 9_500})
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-2001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "op-2002",
                 "status" => "applied",
                 "amount_cents" => 9_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             ] = results
    end

    test "rejects unusable amounts", %{conn: conn} do
      open_group!(conn)

      for {amount, index} <- Enum.with_index([0, -1, "10000", 100.5, true]) do
        [result] =
          post_batch!(fresh_conn(), [
            record_cash_payment_op(%{
              "operation_id" => "op-amount-#{index}",
              "amount_cents" => amount
            })
          ])

        assert result["code"] == "invalid_amount", "amount=#{inspect(amount)}"
      end

      assert Groups.get_group("group-81").deposit_paid_cents == 0
    end

    test "rejects payments above the outstanding deposit", %{conn: conn} do
      open_group!(conn)

      [result] = post_batch!(conn, [record_cash_payment_op(%{"amount_cents" => 19_501})])
      assert result["code"] == "payment_exceeds_outstanding"

      assert Groups.get_group("group-81").deposit_paid_cents == 0
    end

    test "rejects payments for missing groups", %{conn: conn} do
      [result] = post_batch!(conn, [record_cash_payment_op()])
      assert result["code"] == "group_not_found"
    end

    test "rejects payments for cancelled groups", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), cancel_group_op()])

      [result] = post_batch!(fresh_conn(), [record_cash_payment_op()])
      assert result["code"] == "group_not_active"
    end

    test "group status is evaluated before the amount", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), cancel_group_op()])

      [result] =
        post_batch!(fresh_conn(), [record_cash_payment_op(%{"amount_cents" => -5})])

      assert result["code"] == "group_not_active"
    end

    test "rejects payments missing their amount", %{conn: conn} do
      open_group!(conn)

      [result] =
        post_batch!(conn, [record_cash_payment_op() |> Map.delete("amount_cents")])

      assert result["code"] == "invalid_operation"
    end
  end

  describe "reschedule_group" do
    test "moves the stay without changing its length or price", %{conn: conn} do
      apply_batch!(conn, [open_group_op()])

      [result] = post_batch!(conn, [reschedule_group_op()])

      assert result == %{
               "operation_id" => "op-3001",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      group = get_group!(fresh_conn(), "group-81")
      assert group["arrival_on"] == "2026-12-20"
      assert group["departure_on"] == "2026-12-23"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "rejects a new arrival that is not after the operation date", %{conn: conn} do
      open_group!(conn)

      for {new_arrival, index} <-
            Enum.with_index(["2026-10-05", "2026-10-04", "2025-01-01", "not-a-date"]) do
        [result] =
          post_batch!(fresh_conn(), [
            reschedule_group_op(%{
              "operation_id" => "op-arrival-#{index}",
              "new_arrival_on" => new_arrival
            })
          ])

        assert result["code"] == "invalid_stay", "new_arrival=#{new_arrival}"
      end

      assert Groups.get_group("group-81").arrival_on == ~D[2026-12-10]
    end

    test "rejects reschedules for missing or inactive groups", %{conn: conn} do
      [missing] = post_batch!(conn, [reschedule_group_op()])
      assert missing["code"] == "group_not_found"

      apply_batch!(conn, [open_group_op(), cancel_group_op()])

      [inactive] =
        post_batch!(fresh_conn(), [reschedule_group_op(%{"operation_id" => "op-3002"})])

      assert inactive["code"] == "group_not_active"
    end

    test "a reschedule without visible changes still increments the revision", %{conn: conn} do
      open_group!(conn)

      # The current arrival is after the operation date, so moving "to" it is
      # an applied operation that leaves the booking fields unchanged.
      [result] =
        post_batch!(conn, [reschedule_group_op(%{"new_arrival_on" => "2026-12-10"})])

      assert result["status"] == "applied"
      assert result["revision"] == 2
      assert result["new_arrival_on"] == "2026-12-10"
      assert result["new_departure_on"] == "2026-12-13"

      assert Groups.get_group("group-81").revision == 2
    end

    test "group status is evaluated before the new arrival date", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), cancel_group_op()])

      [result] =
        post_batch!(fresh_conn(), [reschedule_group_op(%{"new_arrival_on" => "not-a-date"})])

      assert result["code"] == "group_not_active"
    end
  end

  describe "cancel_group" do
    test "refunds flexible groups cancelled at least 14 days before arrival", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      # 2026-11-26 is exactly 14 days before the 2026-12-10 arrival.
      [result] = post_batch!(conn, [cancel_group_op(%{"occurred_on" => "2026-11-26"})])

      assert result == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 19_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = get_group!(fresh_conn(), "group-81")
      assert group["status"] == "cancelled"
    end

    test "retains cash for flexible groups cancelled inside the refundable window", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      # 2026-11-27 is only 13 days before arrival.
      [result] = post_batch!(conn, [cancel_group_op(%{"occurred_on" => "2026-11-27"})])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 19_500
    end

    test "advance_purchase groups are always non-refundable", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(%{"rate_plan" => "advance_purchase"}),
        record_cash_payment_op(%{"amount_cents" => 97_500})
      ])

      [result] = post_batch!(conn, [cancel_group_op(%{"occurred_on" => "2026-01-01"})])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 97_500
    end

    test "unpaid deposit is simply no longer due", %{conn: conn} do
      apply_batch!(conn, [open_group_op()])

      [result] = post_batch!(conn, [cancel_group_op()])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      group = get_group!(fresh_conn(), "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      assert Ledger.totals().cash_held_cents == 0
    end

    test "a cancelled group rejects further payments, reschedules, and cancellations", %{
      conn: conn
    } do
      apply_batch!(conn, [open_group_op(), cancel_group_op()])

      results =
        post_batch!(fresh_conn(), [
          record_cash_payment_op(%{"operation_id" => "op-pay"}),
          reschedule_group_op(%{"operation_id" => "op-move"}),
          cancel_group_op(%{"operation_id" => "op-cancel"})
        ])

      assert Enum.map(results, & &1["code"]) == [
               "group_not_active",
               "group_not_active",
               "group_not_active"
             ]

      assert Groups.get_group("group-81").revision == 2
    end

    test "rejects cancellations for missing groups", %{conn: conn} do
      [result] = post_batch!(conn, [cancel_group_op()])
      assert result["code"] == "group_not_found"
    end
  end

  describe "revisions" do
    test "each applied operation increments the revision exactly once", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 1_000}),
          reschedule_group_op(),
          cancel_group_op()
        ])

      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
      assert Groups.get_group("group-81").revision == 4
    end

    test "rejected operations never increment the revision", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => -1}),
          record_cash_payment_op(%{"operation_id" => "op-2", "amount_cents" => 999_999}),
          record_cash_payment_op(%{"operation_id" => "op-3", "amount_cents" => 1_000})
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "rejected"},
               %{"status" => "rejected"},
               %{"status" => "applied", "revision" => 2}
             ] = results

      assert Groups.get_group("group-81").revision == 2
    end

    test "expected_revision applies when it matches the current revision", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 1_000, "expected_revision" => 1})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied", "revision" => 2}] = results
    end

    test "expected_revision observes changes from earlier operations in the same batch", %{
      conn: conn
    } do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 1_000}),
          reschedule_group_op(%{"expected_revision" => 2})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]
    end

    test "a stale revision is rejected with the documented fields", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 1_000})
      ])

      [result] =
        post_batch!(conn, [
          record_cash_payment_op(%{
            "operation_id" => "op-2002",
            "amount_cents" => 1_000,
            "expected_revision" => 1
          })
        ])

      assert result == %{
               "operation_id" => "op-2002",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "a stale revision leaves the group and the ledger unchanged", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 1_000})
      ])

      before_group = Groups.get_group("group-81")
      before_ledger = Ledger.totals()

      [result] =
        post_batch!(conn, [
          record_cash_payment_op(%{
            "operation_id" => "op-2002",
            "amount_cents" => 5_000,
            "expected_revision" => 99
          })
        ])

      assert result["code"] == "stale_revision"
      assert Groups.get_group("group-81") == before_group
      assert Ledger.totals() == before_ledger
    end

    test "stale revision is rejected before other domain validation", %{conn: conn} do
      open_group!(conn)

      # The amount is unusable, but the stale revision must win.
      [result] =
        post_batch!(conn, [
          record_cash_payment_op(%{"amount_cents" => -5, "expected_revision" => 7})
        ])

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1
    end

    test "group existence is resolved before the revision is compared", %{conn: conn} do
      [result] =
        post_batch!(conn, [record_cash_payment_op(%{"expected_revision" => 12})])

      assert result["code"] == "group_not_found"
    end

    test "open_group does not use expected_revision", %{conn: conn} do
      [result] = post_batch!(conn, [open_group_op(%{"expected_revision" => 42})])
      assert result["status"] == "applied"
      assert result["revision"] == 1
    end
  end
end
