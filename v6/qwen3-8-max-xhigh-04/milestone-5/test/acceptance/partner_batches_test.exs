defmodule GroupStayWeb.Acceptance.PartnerBatchesTest do
  use GroupStayWeb.ConnCase

  @open_op %{
    "operation_id" => "op-1",
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
  }

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group(conn, overrides \\ %{}) do
    [result] = submit(conn, [Map.merge(@open_op, overrides)])
    assert %{"status" => "applied"} = result
    result
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

  defp reschedule_op(overrides \\ %{}) do
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

  describe "batch shape" do
    test "a body without an operations array is an invalid batch" do
      conn = post(build_conn(), "/api/v1/partner-batches", %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "a non-list operations field is an invalid batch" do
      conn =
        post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{"type" => "open_group"}})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "an empty operations list is accepted" do
      assert submit(build_conn(), []) == []
    end

    test "returns one result per operation, in order" do
      results =
        submit(build_conn(), [
          @open_op,
          payment_op(),
          payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 999_999})
        ])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-pay", "op-pay-2"]
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected"]
    end
  end

  describe "open_group" do
    test "applies the API document example" do
      assert [
               %{
                 "operation_id" => "op-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19500,
                 "revision" => 1
               }
             ] = submit(build_conn(), [@open_op])
    end

    test "the occurred_on date becomes the booked_on date" do
      open_group(build_conn())

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["booked_on"] == "2026-10-03"
    end

    test "an advance_purchase room requires its full lodging amount as deposit" do
      open_group(build_conn(), %{
        "operation_id" => "op-ap",
        "group_id" => "group-ap",
        "rate_plan" => "advance_purchase"
      })

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-ap"), 200)
      assert group["lodging_total_cents"] == 97500
      assert group["deposit_due_cents"] == 97500
    end

    test "rounds each flexible room deposit to the nearest cent before summing" do
      open_group(build_conn(), %{
        "operation_id" => "op-round",
        "group_id" => "group-round",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 10002},
          %{"room_id" => "r2", "nightly_rate_cents" => 10003},
          %{"room_id" => "r3", "nightly_rate_cents" => 10007},
          %{"room_id" => "r4", "nightly_rate_cents" => 10008}
        ]
      })

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-round"), 200)
      # 2000.4 -> 2000, 2000.6 -> 2001, 2001.4 -> 2001, 2001.6 -> 2002
      assert group["deposit_due_cents"] == 8004
      assert group["lodging_total_cents"] == 40020
    end

    test "rejects a duplicate group identifier" do
      open_group(build_conn())

      assert [
               %{
                 "operation_id" => "op-dup",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               }
             ] = submit(build_conn(), [Map.put(@open_op, "operation_id", "op-dup")])
    end

    test "rejects a stay without at least one night" do
      for {arrival, departure} <- [{"2026-12-10", "2026-12-10"}, {"2026-12-13", "2026-12-10"}] do
        assert [
                 %{"status" => "rejected", "code" => "invalid_stay"}
               ] =
                 submit(build_conn(), [
                   @open_op
                   |> Map.put("operation_id", "op-stay-#{arrival}-#{departure}")
                   |> Map.put("arrival_on", arrival)
                   |> Map.put("departure_on", departure)
                   |> Map.put("group_id", "group-#{arrival}-#{departure}")
                 ])
      end
    end

    test "rejects rooms that are not usable" do
      cases = [
        [],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
        [%{"room_id" => "room-a"}, %{"nightly_rate_cents" => 15000}],
        [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
        ]
      ]

      cases
      |> Enum.with_index()
      |> Enum.each(fn {rooms, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
                 submit(build_conn(), [
                   @open_op
                   |> Map.put("operation_id", "op-rooms-#{index}")
                   |> Map.put("rooms", rooms)
                 ])
      end)
    end

    test "rejects an unknown rate plan" do
      assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] =
               submit(build_conn(), [Map.put(@open_op, "rate_plan", "semi-flex")])
    end

    test "rejects operations missing data needed to apply them" do
      missing_field_cases = [
        Map.delete(@open_op, "occurred_on"),
        Map.delete(@open_op, "group_id"),
        Map.delete(@open_op, "guest_id"),
        Map.delete(@open_op, "property_id"),
        Map.delete(@open_op, "arrival_on"),
        Map.delete(@open_op, "departure_on"),
        Map.delete(@open_op, "rate_plan"),
        Map.delete(@open_op, "rooms"),
        Map.put(@open_op, "arrival_on", "not-a-date"),
        Map.put(@open_op, "rooms", %{"room_id" => "room-a"})
      ]

      missing_field_cases
      |> Enum.with_index()
      |> Enum.each(fn {op, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
                 submit(build_conn(), [Map.put(op, "operation_id", "op-invalid-#{index}")])
      end)
    end

    test "rejects an unknown operation type" do
      assert [%{"operation_id" => "op-x", "status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-x",
                   "type" => "extend_group",
                   "occurred_on" => "2026-10-03"
                 }
               ])
    end

    test "rejects a non-map operation" do
      assert [%{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), ["not-an-operation"])
    end

    test "a rejected open does not create the group" do
      submit(build_conn(), [Map.put(@open_op, "rate_plan", "bogus")])

      assert json_response(get(build_conn(), "/api/v1/groups/group-81"), 404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end

    test "open_group ignores expected_revision" do
      assert [%{"status" => "applied", "revision" => 1}] =
               submit(build_conn(), [Map.put(@open_op, "expected_revision", 99)])
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit" do
      open_group(build_conn())

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 14500,
                 "revision" => 2
               }
             ] = submit(build_conn(), [payment_op()])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["deposit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 14500
    end

    test "accepts a payment of exactly the outstanding deposit" do
      open_group(build_conn())

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0}] =
               submit(build_conn(), [payment_op(%{"amount_cents" => 19500})])
    end

    test "rejects a payment for a missing group" do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [payment_op(%{"group_id" => "nope"})])
    end

    test "rejects a payment for a cancelled group" do
      open_group(build_conn())
      submit(build_conn(), [cancel_op()])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               submit(build_conn(), [payment_op()])
    end

    test "rejects amounts that are not usable as a payment" do
      open_group(build_conn())

      [0, -500, "5000", 50.5, nil]
      |> Enum.with_index()
      |> Enum.each(fn {amount, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(build_conn(), [
                   payment_op(%{
                     "operation_id" => "op-pay-invalid-#{index}",
                     "amount_cents" => amount
                   })
                 ])
      end)
    end

    test "rejects a missing amount" do
      open_group(build_conn())

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [payment_op() |> Map.delete("amount_cents")])
    end

    test "rejects a payment exceeding the outstanding deposit" do
      open_group(build_conn())

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               submit(build_conn(), [payment_op(%{"amount_cents" => 19501})])
    end

    test "a rejected payment leaves the group unchanged" do
      open_group(build_conn())
      submit(build_conn(), [payment_op(%{"amount_cents" => 999_999})])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end
  end

  describe "reschedule_group" do
    test "shifts the departure by the same number of days" do
      open_group(build_conn())

      assert [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-15",
                 "new_departure_on" => "2026-12-18",
                 "revision" => 2
               }
             ] = submit(build_conn(), [reschedule_op()])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["arrival_on"] == "2026-12-15"
      assert group["departure_on"] == "2026-12-18"
      assert group["lodging_total_cents"] == 97500
      assert group["deposit_due_cents"] == 19500
    end

    test "rejects a new arrival that is not after the operation date" do
      open_group(build_conn())

      for new_arrival <- ["2026-10-04", "2026-10-03", "2026-09-01"] do
        assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
                 submit(build_conn(), [
                   reschedule_op(%{
                     "operation_id" => "op-move-#{new_arrival}",
                     "new_arrival_on" => new_arrival
                   })
                 ])
      end
    end

    test "rejects an unusable new arrival date" do
      open_group(build_conn())

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [reschedule_op(%{"new_arrival_on" => "soon"})])
    end

    test "rejects a missing group" do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [reschedule_op(%{"group_id" => "nope"})])
    end

    test "rejects a cancelled group" do
      open_group(build_conn())
      submit(build_conn(), [cancel_op()])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               submit(build_conn(), [reschedule_op()])
    end
  end

  describe "cancel_group" do
    test "a flexible cancellation at least 14 days before arrival refunds paid cash" do
      open_group(build_conn())
      submit(build_conn(), [payment_op(%{"amount_cents" => 8000})])

      assert [
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 8000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = submit(build_conn(), [cancel_op(%{"occurred_on" => "2026-11-26"})])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["status"] == "cancelled"
    end

    test "a flexible cancellation exactly 14 days before arrival is refundable" do
      open_group(build_conn())
      submit(build_conn(), [payment_op(%{"amount_cents" => 8000})])

      assert [%{"status" => "applied", "refunded_cents" => 8000, "retained_cents" => 0}] =
               submit(build_conn(), [cancel_op(%{"occurred_on" => "2026-11-26"})])
    end

    test "a flexible cancellation 13 days before arrival retains paid cash" do
      open_group(build_conn())
      submit(build_conn(), [payment_op(%{"amount_cents" => 8000})])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 8000}] =
               submit(build_conn(), [cancel_op(%{"occurred_on" => "2026-11-27"})])
    end

    test "an advance-purchase cancellation is always non-refundable" do
      open_group(build_conn(), %{
        "operation_id" => "op-ap",
        "group_id" => "group-ap",
        "rate_plan" => "advance_purchase"
      })

      submit(build_conn(), [payment_op(%{"group_id" => "group-ap", "amount_cents" => 8000})])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 8000}] =
               submit(build_conn(), [
                 cancel_op(%{"group_id" => "group-ap", "occurred_on" => "2026-10-04"})
               ])
    end

    test "unpaid deposit is no longer due after cancellation" do
      open_group(build_conn())

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] =
               submit(build_conn(), [cancel_op()])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0
    end

    test "rejects a missing group" do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [cancel_op(%{"group_id" => "nope"})])
    end

    test "later operations on a cancelled group are rejected" do
      open_group(build_conn())
      submit(build_conn(), [cancel_op()])

      assert [
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] =
               submit(build_conn(), [
                 payment_op(),
                 reschedule_op(),
                 cancel_op(%{"operation_id" => "op-cancel-again"})
               ])
    end
  end

  describe "revisions" do
    test "every applied operation increments the revision exactly once" do
      open_group(build_conn())

      assert [%{"revision" => 2}] = submit(build_conn(), [payment_op()])
      assert [%{"revision" => 3}] = submit(build_conn(), [reschedule_op()])
      assert [%{"revision" => 4}] = submit(build_conn(), [cancel_op()])
    end

    test "rejections never increment the revision" do
      open_group(build_conn())

      submit(build_conn(), [
        payment_op(%{"amount_cents" => 999_999}),
        reschedule_op(%{"new_arrival_on" => "2026-10-04"}),
        payment_op(%{"operation_id" => "op-pay-missing", "group_id" => "nope"})
      ])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["revision"] == 1
    end

    test "a matching expected_revision applies and returns the new revision" do
      open_group(build_conn())

      assert [%{"status" => "applied", "revision" => 2}] =
               submit(build_conn(), [payment_op(%{"expected_revision" => 1})])
    end

    test "a stale expected_revision is rejected with the documented fields" do
      open_group(build_conn())
      submit(build_conn(), [payment_op()])

      assert [
               %{
                 "operation_id" => "op-pay-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] =
               submit(build_conn(), [
                 payment_op(%{"operation_id" => "op-pay-stale", "expected_revision" => 1})
               ])
    end

    test "a stale rejection leaves the group and ledger unchanged" do
      open_group(build_conn())
      submit(build_conn(), [payment_op(%{"amount_cents" => 5000})])

      before_ledger = json_response(get(build_conn(), "/api/v1/ledger"), 200)

      submit(build_conn(), [
        payment_op(%{
          "operation_id" => "op-pay-stale",
          "amount_cents" => 3000,
          "expected_revision" => 1
        })
      ])

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5000
      assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == before_ledger
    end

    test "group existence is resolved before comparing revisions" do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [
                 payment_op(%{"group_id" => "nope", "expected_revision" => 1})
               ])
    end

    test "omitting expected_revision preserves unconditional behavior" do
      open_group(build_conn())
      submit(build_conn(), [payment_op()])

      assert [%{"status" => "applied", "revision" => 3}] =
               submit(build_conn(), [payment_op(%{"operation_id" => "op-pay-2"})])
    end
  end

  describe "batch processing" do
    test "an operation observes changes made earlier in the same batch" do
      assert [%{"status" => "applied"}, %{"status" => "applied", "revision" => 2}] =
               submit(build_conn(), [
                 @open_op,
                 payment_op(%{"expected_revision" => 1})
               ])
    end

    test "a rejected operation does not undo earlier success or stop later operations" do
      results =
        submit(build_conn(), [
          @open_op,
          payment_op(%{"amount_cents" => 999_999}),
          payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied"]

      %{"data" => group} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert group["deposit_paid_cents"] == 1000
      assert group["revision"] == 2
    end

    test "every rejection leaves the database as it was before that operation" do
      open_group(build_conn())

      %{"data" => before} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      ledger_before = json_response(get(build_conn(), "/api/v1/ledger"), 200)

      submit(build_conn(), [
        Map.put(@open_op, "operation_id", "op-dup"),
        payment_op(%{"amount_cents" => 0}),
        reschedule_op(%{"new_arrival_on" => "2026-10-04"}),
        cancel_op(%{"group_id" => "nope"}),
        payment_op(%{"operation_id" => "op-pay-stale", "expected_revision" => 99})
      ])

      %{"data" => after_} = json_response(get(build_conn(), "/api/v1/groups/group-81"), 200)
      assert after_ == before
      assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == ledger_before
    end
  end
end
