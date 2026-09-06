defmodule GroupStayWeb.Controllers.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  ## Operation builders

  defp payment(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reschedule(new_arrival, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81",
        "new_arrival_on" => new_arrival
      },
      overrides
    )
  end

  defp cancel(overrides \\ %{}) do
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

  defp assert_ledger(conn, expectations) do
    assert fetch_ledger(conn) == Map.new(expectations, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  describe "POST /api/v1/partner-batches with open_group" do
    test "opens a group and reports the applied result", %{conn: conn} do
      results = run_batch(conn, [open_operation(%{"operation_id" => "op-1001"})])

      assert results == [
               %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
    end

    test "stores the opened group for reads", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{
          "occurred_on" => "2026-10-03",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        })
      ])

      assert %{
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
             } = fetch_group(conn, "group-81")
    end

    test "keeps rooms in their original order regardless of identifiers", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{
          "rooms" => [
            %{"room_id" => "z-room", "nightly_rate_cents" => 10_000},
            %{"room_id" => "a-room", "nightly_rate_cents" => 11_000},
            %{"room_id" => "m-room", "nightly_rate_cents" => 12_000}
          ]
        })
      ])

      assert [%{"room_id" => "z-room"}, %{"room_id" => "a-room"}, %{"room_id" => "m-room"}] =
               fetch_group(conn, "group-81")["rooms"]
    end

    test "rounds each flexible room deposit separately", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 9},
            %{"room_id" => "room-b", "nightly_rate_cents" => 8}
          ]
        })
      ])

      # Per room half-up rounding gives 2 + 2 = 4; a lump-sum calculation would give 3.
      assert %{"deposit_due_cents" => 4, "lodging_total_cents" => 17} =
               fetch_group(conn, "group-81")
    end

    test "charges the full lodging amount for advance_purchase rooms", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })
      ])

      group = fetch_group(conn, "group-81")
      assert group["deposit_due_cents"] == 45_000
      assert group["lodging_total_cents"] == 45_000
    end

    test "rejects a duplicate group identifier without touching the existing group", %{conn: conn} do
      run_batch(conn, [open_operation()])

      results =
        run_batch(conn, [
          open_operation(%{"operation_id" => "op-dup", "guest_id" => "guest-other"})
        ])

      assert results == [
               %{
                 "operation_id" => "op-dup",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               }
             ]

      group = fetch_group(conn, "group-81")
      assert group["guest_id"] == "guest-22"
      assert group["revision"] == 1
    end

    test "room identifiers only need to be unique within a group", %{conn: conn} do
      rooms = [%{"room_id" => "shared-room", "nightly_rate_cents" => 15_000}]

      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               run_batch(conn, [
                 open_operation(%{"group_id" => "g-one", "rooms" => rooms}),
                 open_operation(%{"group_id" => "g-two", "rooms" => rooms})
               ])

      assert fetch_group(conn, "g-one")["rooms"] == fetch_group(conn, "g-two")["rooms"]
    end

    test "rejects a stay without at least one night", %{conn: conn} do
      for {arrival, departure} <- [{"2026-12-10", "2026-12-10"}, {"2026-12-13", "2026-12-10"}] do
        results =
          run_batch(conn, [
            open_operation(%{
              "operation_id" => "op-stay",
              "arrival_on" => arrival,
              "departure_on" => departure
            })
          ])

        assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
      end

      assert fetch_group(conn, "group-81") == nil
    end

    test "rejects unparsable stay dates", %{conn: conn} do
      for override <- [
            %{"arrival_on" => "not-a-date"},
            %{"departure_on" => "12/13/2026"},
            %{"departure_on" => nil}
          ] do
        results =
          run_batch(conn, [open_operation(Map.merge(%{"operation_id" => "op-date"}, override))])

        assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
      end

      assert fetch_group(conn, "group-81") == nil
    end

    test "rejects unusable rooms lists", %{conn: conn} do
      rooms_variants = [
        [],
        nil,
        [%{"room_id" => "room-a"}, %{"room_id" => "room-a"}],
        [%{"room_id" => "", "nightly_rate_cents" => 1_000}],
        [%{"nightly_rate_cents" => 1_000}],
        [%{"room_id" => "room-a"}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => -5_000}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 1.5}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
        ["room-a"],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 1_000}, "not-a-room"]
      ]

      for variant <- rooms_variants do
        operation =
          case variant do
            nil ->
              Map.delete(open_operation(%{"operation_id" => "op-room"}), "rooms")

            rooms ->
              open_operation(%{"operation_id" => "op-room", "rooms" => rooms})
          end

        assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
                 run_batch(conn, [operation])
      end

      assert fetch_group(conn, "group-81") == nil
    end

    test "rejects unknown or missing rate plans", %{conn: conn} do
      for rate_plan <- ["standard", "", nil] do
        results =
          run_batch(conn, [
            open_operation(%{"operation_id" => "op-plan", "rate_plan" => rate_plan})
          ])

        assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] = results
      end

      assert fetch_group(conn, "group-81") == nil
    end

    test "rejects operations missing data needed to identify or apply them", %{conn: conn} do
      operations = [
        open_operation(%{"operation_id" => nil}),
        Map.delete(open_operation(), "operation_id"),
        open_operation(%{"type" => "close_group"}),
        open_operation(%{"group_id" => ""}),
        Map.delete(open_operation(), "group_id"),
        open_operation(%{"guest_id" => "   "}),
        Map.delete(open_operation(), "property_id"),
        open_operation(%{"occurred_on" => "October 3rd"}),
        Map.delete(open_operation(), "occurred_on")
      ]

      results = run_batch(conn, operations)
      assert length(results) == length(operations)

      Enum.each(results, fn result ->
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end)

      assert fetch_group(conn, "group-81") == nil
    end

    test "rejects operations that are not objects and echoes no operation id", %{conn: conn} do
      results = run_batch(conn, ["open_group", 42])

      assert results == [
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"},
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
             ]
    end

    test "returns partner-supplied identifiers unchanged", %{conn: conn} do
      results = run_batch(conn, [open_operation(%{"operation_id" => "op/with:symbols ✈"})])

      assert [%{"operation_id" => "op/with:symbols ✈", "group_id" => "group-81"}] = results
    end
  end

  describe "POST /api/v1/partner-batches with record_cash_payment" do
    test "applies cash to the outstanding deposit exactly once per operation", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ] = run_batch(conn, [payment("group-81", 5_000)])

      group = fetch_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 5_000
      assert group["outstanding_deposit_cents"] == 14_500
      assert group["revision"] == 2
    end

    test "allows paying the deposit in full but not a cent more", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2}] =
               run_batch(conn, [payment("group-81", 19_500)])

      results = run_batch(conn, [payment("group-81", 1)])

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] = results
      refute Map.has_key?(hd(results), "revision")

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 19_500
    end

    test "rejects payments to missing groups before other rules", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               run_batch(conn, [payment("nope", -1)])
    end

    test "rejects unusable payment amounts", %{conn: conn} do
      run_batch(conn, [open_operation()])

      for amount <- [0, -1, 1.5, "5000", nil] do
        results = run_batch(conn, [payment("group-81", amount)])
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] = results
      end

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 0
    end

    test "rejects payments to cancelled groups", %{conn: conn} do
      run_batch(conn, [open_operation(), cancel()])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               run_batch(conn, [payment("group-81", 1_000)])
    end
  end

  describe "POST /api/v1/partner-batches with reschedule_group" do
    test "shifts the departure by the same number of nights without changing price", %{conn: conn} do
      run_batch(conn, [open_operation()])
      original = fetch_group(conn, "group-81")

      assert [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-01-05",
                 "new_departure_on" => "2027-01-08",
                 "revision" => 2
               }
             ] = run_batch(conn, [reschedule("2027-01-05")])

      moved = fetch_group(conn, "group-81")
      assert moved["arrival_on"] == "2027-01-05"
      assert moved["departure_on"] == "2027-01-08"
      assert moved["lodging_total_cents"] == original["lodging_total_cents"]
      assert moved["deposit_due_cents"] == original["deposit_due_cents"]
      assert moved["booked_on"] == original["booked_on"]
    end

    test "rejects arrivals that are not after the operation date", %{conn: conn} do
      run_batch(conn, [open_operation()])

      for new_arrival <- ["2026-11-19", "2026-11-20", "garbage", nil] do
        results = run_batch(conn, [reschedule(new_arrival)])
        assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
      end

      group = fetch_group(conn, "group-81")
      assert group["arrival_on"] == "2026-12-10"
      assert group["revision"] == 1
    end

    test "uses the existing group errors for missing or inactive groups", %{conn: conn} do
      run_batch(conn, [open_operation(), cancel()])

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               run_batch(conn, [reschedule("2027-02-01", %{"group_id" => "missing"})])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               run_batch(conn, [reschedule("2027-02-01")])
    end
  end

  describe "POST /api/v1/partner-batches with cancel_group" do
    test "refunds flexible reservations cancelled at least 14 days before arrival", %{conn: conn} do
      run_batch(conn, [open_operation(), payment("group-81", 5_000)])

      assert [
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = run_batch(conn, [cancel()])

      assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 5_000, cash_retained_cents: 0)
    end

    test "keeps the boundary: 14 days refunds, 13 days retains", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"group_id" => "g-14"}),
        payment("g-14", 5_000),
        open_operation(%{"group_id" => "g-13", "arrival_on" => "2026-12-11"}),
        payment("g-13", 5_000, %{"operation_id" => "op-pay-13"})
      ])

      assert [%{"status" => "applied", "refunded_cents" => 5_000, "retained_cents" => 0}] =
               run_batch(conn, [cancel(%{"group_id" => "g-14"})])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5_000}] =
               run_batch(conn, [cancel(%{"group_id" => "g-13", "occurred_on" => "2026-11-28"})])
    end

    test "retains cash for flexible reservations cancelled inside 14 days", %{conn: conn} do
      run_batch(conn, [open_operation(), payment("group-81", 19_500)])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 19_500}] =
               run_batch(conn, [cancel(%{"occurred_on" => "2026-11-30"})])
    end

    test "always retains cash for advance_purchase reservations", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"rate_plan" => "advance_purchase"}),
        payment("group-81", 45_000)
      ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 45_000}] =
               run_batch(conn, [cancel(%{"occurred_on" => "2026-10-04"})])
    end

    test "cancelling an unfunded group still applies and increments the revision", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 2
               }
             ] =
               run_batch(conn, [cancel()])

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["revision"] == 2
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
      assert group["lodging_total_cents"] == 97_500
    end

    test "rejects later payments, reschedules, and cancellations once cancelled", %{conn: conn} do
      run_batch(conn, [open_operation(), cancel()])

      follow_ups = [
        payment("group-81", 1_000, %{"operation_id" => "op-pay-late"}),
        reschedule("2027-03-01", %{"operation_id" => "op-move-late"}),
        cancel(%{"operation_id" => "op-cancel-late", "occurred_on" => "2026-11-27"})
      ]

      results = run_batch(conn, follow_ups)

      Enum.each(results, fn result ->
        assert result["status"] == "rejected"
        assert result["code"] == "group_not_active"
      end)

      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "rejects cancelling missing groups", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               run_batch(conn, [cancel(%{"group_id" => "ghost"})])
    end
  end

  describe "expected_revision handling" do
    test "rejects a stale revision before other domain validation and changes nothing", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 2,
                 "actual_revision" => 1
               }
             ] =
               run_batch(conn, [
                 payment("group-81", -5, %{"expected_revision" => 2})
               ])

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0

      assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0)
    end

    test "stale revision wins over inactive groups", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        cancel(%{"expected_revision" => 1})
      ])

      assert [%{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2}] =
               run_batch(conn, [
                 payment("group-81", 100, %{
                   "expected_revision" => 1,
                   "occurred_on" => "2026-11-02"
                 })
               ])
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               run_batch(conn, [
                 payment("missing", 100, %{"expected_revision" => 99})
               ])
    end

    test "omitting expected_revision preserves unconditional behavior", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert [
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3}
             ] =
               run_batch(conn, [
                 payment("group-81", 1_000),
                 payment("group-81", 1_000, %{"expected_revision" => nil})
               ])
    end

    test "operations without an operation date are rejected", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               run_batch(conn, [reschedule("2027-01-05", %{"occurred_on" => nil})])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               run_batch(conn, [cancel(%{"occurred_on" => nil})])
    end
  end

  describe "batch processing" do
    test "processes operations in order with later operations observing earlier ones", %{
      conn: conn
    } do
      results =
        run_batch(conn, [
          open_operation(%{"operation_id" => "op-1"}),
          payment("group-81", 19_500, %{
            "operation_id" => "op-2",
            "occurred_on" => "2026-10-05",
            "expected_revision" => 1
          }),
          reschedule("2026-12-24", %{
            "operation_id" => "op-3",
            "expected_revision" => 2
          }),
          cancel(%{
            "operation_id" => "op-4",
            "expected_revision" => 3
          })
        ])

      assert [
               %{"operation_id" => "op-1", "status" => "applied", "revision" => 1},
               %{"operation_id" => "op-2", "status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "op-3",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-24",
                 "new_departure_on" => "2026-12-27",
                 "revision" => 3
               },
               %{
                 "operation_id" => "op-4",
                 "status" => "applied",
                 "refunded_cents" => 19_500,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ] = results

      assert fetch_group(conn, "group-81")["status"] == "cancelled"

      assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 19_500, cash_retained_cents: 0)
    end

    test "a rejected operation does not undo earlier operations nor stop later ones", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])

      results =
        run_batch(conn, [
          payment("group-81", 2_000, %{"operation_id" => "op-good-1"}),
          open_operation(%{"operation_id" => "op-duplicate"}),
          payment("group-81", 3_000, %{
            "operation_id" => "op-good-2",
            "expected_revision" => 2
          }),
          payment("group-81", 999_999, %{"operation_id" => "op-too-much"})
        ])

      assert [
               %{"operation_id" => "op-good-1", "status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "op-duplicate",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               },
               %{"operation_id" => "op-good-2", "status" => "applied", "revision" => 3},
               %{
                 "operation_id" => "op-too-much",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               }
             ] = results

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 5_000
    end

    test "an operation cannot observe a group opened later in the same batch", %{conn: conn} do
      results =
        run_batch(conn, [
          payment("group-81", 100, %{"operation_id" => "op-early-pay"}),
          open_operation()
        ])

      assert [
               %{
                 "operation_id" => "op-early-pay",
                 "status" => "rejected",
                 "code" => "group_not_found"
               },
               %{"operation_id" => "op-open", "status" => "applied"}
             ] = results
    end

    test "rejected opens leave nothing behind", %{conn: conn} do
      run_batch(conn, [open_operation(%{"operation_id" => "op-bad", "rate_plan" => "standard"})])

      assert fetch_group(conn, "group-81") == nil
      assert_ledger(conn, cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0)
    end

    test "an empty batch succeeds with no results", %{conn: conn} do
      assert run_batch(conn, []) == []
    end
  end

  describe "invalid batches" do
    test "a body without an operations array returns 422 invalid_batch", %{conn: conn} do
      for body <- [
            %{},
            %{"operations" => "nope"},
            %{"operations" => %{"type" => "open_group"}}
          ] do
        response = post(conn, "/api/v1/partner-batches", body)
        assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "a body that is not a JSON object returns 422 invalid_batch", %{conn: conn} do
      response = submit_raw_batch(conn, "[1,2,3]")

      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end
end
