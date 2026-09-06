defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches with open_group" do
    test "applies the API example operation", %{conn: conn} do
      conn = post_operations(conn, [open_operation()])

      assert json_response(conn, 200) == %{
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
    end

    test "rounds each flexible room deposit separately", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 11_111},
        %{"room_id" => "room-b", "nightly_rate_cents" => 11_111}
      ]

      op =
        open_operation(%{
          "group_id" => "rounding-group",
          "rooms" => rooms,
          "rate_plan" => "flexible"
        })

      conn = post_operations(conn, [op])

      assert %{"status" => "applied", "deposit_due_cents" => 13_334} =
               hd(json_response(conn, 200)["results"])

      # Each room lodges 3 * 11111 = 33333; 20% rounds to 6667 per room.
      # A naive group-level calculation would round 66666 * 20% to 13333 instead.
      assert %{
               "data" => %{
                 "lodging_total_cents" => 66_666,
                 "deposit_due_cents" => 13_334,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 13_334
               }
             } = get_group(conn, "rounding-group") |> json_response(200)
    end

    test "advance_purchase deposits the full lodging amount", %{conn: conn} do
      op =
        open_operation(%{
          "group_id" => "advance-group",
          "guest_id" => "guest-7",
          "property_id" => "rtm-harbor",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_001}]
        })

      conn = post_operations(conn, [op])

      assert %{"status" => "applied", "deposit_due_cents" => 30_003, "revision" => 1} =
               hd(json_response(conn, 200)["results"])
    end

    test "rejects a stay without at least one night and creates nothing", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{"departure_on" => "2026-12-10"})
        ])

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
               json_response(conn, 200)["results"]

      assert %{"error" => %{"code" => "group_not_found"}} =
               get_group(conn, "group-81") |> json_response(404)
    end

    test "rejects an arrival after departure", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{"arrival_on" => "2026-12-14", "departure_on" => "2026-12-13"})
        ])

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects unusable stay dates", %{conn: conn} do
      for overrides <- [
            %{"arrival_on" => "not-a-date"},
            %{"departure_on" => "2026-12-40"},
            %{"arrival_on" => nil}
          ] do
        conn = post_operations(conn, [open_operation(overrides)])

        assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
                 json_response(conn, 200)["results"]
      end
    end

    test "rejects invalid rooms", %{conn: conn} do
      invalid_rooms = [
        [],
        [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 16000}
        ],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
        [%{"nightly_rate_cents" => 15000}],
        [%{"room_id" => "", "nightly_rate_cents" => 15000}]
      ]

      for rooms <- invalid_rooms do
        conn = post_operations(conn, [open_operation(%{"rooms" => rooms})])

        assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
                 json_response(conn, 200)["results"]
      end
    end

    test "rejects a missing rooms list", %{conn: conn} do
      op = Map.delete(open_operation(), "rooms")
      conn = post_operations(conn, [op])

      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects unknown rate plans", %{conn: conn} do
      conn = post_operations(conn, [open_operation(%{"rate_plan" => "super_saver"})])

      assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects duplicate group ids across batches and within one batch", %{conn: conn} do
      conn = post_operations(conn, [open_operation()])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = post_operations(conn, [open_operation(%{"operation_id" => "op-dup"})])

      assert [%{"status" => "rejected", "code" => "group_already_exists"}] =
               json_response(conn, 200)["results"]

      conn =
        post_operations(conn, [
          open_operation(%{"operation_id" => "op-first", "group_id" => "batch-dup-group"}),
          open_operation(%{"operation_id" => "op-second", "group_id" => "batch-dup-group"}),
          open_operation(%{"operation_id" => "op-third", "group_id" => "other-group"})
        ])

      assert [
               %{"status" => "applied", "group_id" => "batch-dup-group"},
               %{
                 "status" => "rejected",
                 "code" => "group_already_exists",
                 "group_id" => "batch-dup-group"
               },
               %{"status" => "applied", "group_id" => "other-group"}
             ] = json_response(conn, 200)["results"]
    end

    test "records the operation date as booked_on and keeps partner identifiers", %{conn: conn} do
      conn = post_operations(conn, [open_operation()])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "booked_on" => "2026-10-03",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal"
               }
             } = get_group(conn, "group-81") |> json_response(200)
    end
  end

  describe "POST /api/v1/partner-batches batch handling" do
    test "processes operations in order and lets later operations observe earlier ones", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation("group-81", 19_500),
        payment_operation("group-81", 1)
      ]

      conn = post_operations(conn, operations)

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 19_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 2
               },
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]
    end

    test "a rejection does not stop later operations nor undo earlier ones", %{conn: conn} do
      operations = [
        open_operation(),
        %{"operation_id" => "op-bogus", "type" => "teleport_group", "group_id" => "group-81"},
        payment_operation("group-81", 5000)
      ]

      conn = post_operations(conn, operations)

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_operation"},
               %{"status" => "applied", "outstanding_deposit_cents" => 14_500, "revision" => 2}
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5000}} =
               get_group(conn, "group-81") |> json_response(200)
    end

    test "a failed open leaves no partial group behind", %{conn: conn} do
      operations = [
        open_operation(%{"rooms" => []}),
        open_operation()
      ]

      conn = post_operations(conn, operations)

      assert [
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "applied", "revision" => 1}
             ] = json_response(conn, 200)["results"]
    end

    test "returns 422 for bodies without an operations array", %{conn: conn} do
      for body <- [%{}, %{"operations" => "nope"}, %{"operations" => %{"type" => "open_group"}}] do
        conn = post(conn, "/api/v1/partner-batches", body)
        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end

      assert %{"error" => %{"code" => "group_not_found"}} =
               get_group(conn, "group-81") |> json_response(404)
    end
  end

  describe "invalid_operation rejections" do
    test "unknown operation types are rejected and echo the supplied id", %{conn: conn} do
      conn =
        post_operations(conn, [
          %{"operation_id" => "op-42", "type" => "shrink_group", "group_id" => "group-81"}
        ])

      assert [%{"operation_id" => "op-42", "status" => "rejected", "code" => "invalid_operation"}] =
               json_response(conn, 200)["results"]
    end

    test "operations missing identifying data are rejected", %{conn: conn} do
      results =
        [
          %{
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-01",
            "amount_cents" => 100
          },
          %{"operation_id" => "op-nodate", "type" => "cancel_group", "group_id" => "group-81"},
          %{
            "operation_id" => "op-nogroup",
            "type" => "open_group",
            "occurred_on" => "2026-10-03"
          },
          open_operation(%{"occurred_on" => "October third"})
        ]
        |> then(fn ops -> post_operations(conn, ops) end)
        |> json_response(200)
        |> Map.fetch!("results")

      assert [
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"},
               %{
                 "operation_id" => "op-nodate",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "op-nogroup",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"status" => "rejected", "code" => "invalid_operation"}
             ] = results
    end

    test "non-string optional identifiers are rejected as malformed operations", %{conn: conn} do
      conn = post_operations(conn, [open_operation(%{"guest_id" => 22})])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               json_response(conn, 200)["results"]
    end
  end

  describe "record_cash_payment" do
    test "applies cash and reports the remaining outstanding deposit", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 2500)
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-payment",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 2500,
                 "outstanding_deposit_cents" => 17_000,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 2500,
                 "outstanding_deposit_cents" => 17_000
               }
             } = get_group(conn, "group-81") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 2500}} = get_ledger(conn) |> json_response(200)
    end

    test "rejects amounts not usable as payments", %{conn: conn} do
      bad_amounts = [0, -100, "2500", 25.5, true]

      operations =
        Enum.map(Enum.with_index(bad_amounts), fn {bad_amount, index} ->
          [
            open_operation(%{
              "operation_id" => "op-open-#{index}",
              "group_id" => "group-#{index}"
            }),
            payment_operation("group-#{index}", bad_amount)
          ]
        end)
        |> List.flatten()

      results =
        conn |> post_operations(operations) |> json_response(200) |> Map.fetch!("results")

      assert Enum.all?(results, fn result ->
               case result["status"] do
                 "applied" -> result["deposit_due_cents"] == 19_500
                 "rejected" -> result["code"] == "invalid_amount"
                 _other -> false
               end
             end)

      assert length(results) == 10

      assert %{"data" => %{"deposit_paid_cents" => 0}} =
               get_group(conn, "group-0") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 0}} = get_ledger(conn) |> json_response(200)
    end

    test "rejects payments exceeding the outstanding deposit and keeps state clean", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 20_000),
          payment_operation("group-81", 19_000)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "outstanding_deposit_cents" => 500, "revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects payments for missing or inactive groups", %{conn: conn} do
      conn =
        post_operations(conn, [
          payment_operation("ghost-group", 1000),
          open_operation(),
          cancel_operation("group-81"),
          payment_operation("group-81", 1000, %{"operation_id" => "op-late-pay"})
        ])

      assert [
               %{"status" => "rejected", "code" => "group_not_found"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "reschedule_group" do
    test "moves the stay by the same number of days without changing money", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          reschedule_operation("group-81", "2026-12-20")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-reschedule",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             } = get_group(conn, "group-81") |> json_response(200)
    end

    test "requires the new arrival to fall after the operation date", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          reschedule_operation("group-81", "2026-10-31"),
          reschedule_operation("group-81", "2026-11-01", %{"operation_id" => "op-same-day"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_stay"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects reschedules for missing or inactive groups", %{conn: conn} do
      conn =
        post_operations(conn, [
          reschedule_operation("ghost-group", "2026-12-20"),
          open_operation(),
          cancel_operation("group-81"),
          reschedule_operation("group-81", "2026-12-20", %{"operation_id" => "op-late-move"})
        ])

      assert [
               %{"status" => "rejected", "code" => "group_not_found"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "cancel_group" do
    setup %{conn: conn} do
      paid =
        conn
        |> post_operations([open_operation(), payment_operation("group-81", 6000)])
        |> json_response(200)

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = paid["results"]

      {:ok, conn: conn}
    end

    test "refunds flexible reservations cancelled at least 14 days before arrival", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [cancel_operation("group-81", %{"occurred_on" => "2026-11-26"})])

      assert [
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 6000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             } = get_group(conn, "group-81") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 6000,
                 "cash_retained_cents" => 0
               }
             } = get_ledger(conn) |> json_response(200)
    end

    test "retains flexible reservations cancelled fewer than 14 days before arrival", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [cancel_operation("group-81", %{"occurred_on" => "2026-11-27"})])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 6000,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"cash_held_cents" => 0, "cash_retained_cents" => 6000}} =
               get_ledger(conn) |> json_response(200)
    end

    test "always retains advance_purchase reservations regardless of notice", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "advance-group",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 9000}]
          }),
          payment_operation("advance-group", 27_000),
          cancel_operation("advance-group", %{"occurred_on" => "2026-10-05"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 27_000}
             ] = json_response(conn, 200)["results"]

      # The paid cash on still-active group-81 from setup remains held.
      assert %{
               "data" => %{
                 "cash_held_cents" => 6000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 27_000
               }
             } = get_ledger(conn) |> json_response(200)
    end

    test "unpaid deposit simply disappears on cancellation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "unpaid-group",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          }),
          cancel_operation("unpaid-group")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"outstanding_deposit_cents" => 0}} =
               get_group(conn, "unpaid-group") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 6000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = get_ledger(conn) |> json_response(200)
    end

    test "cancelled groups reject later payments, reschedules and cancellations", %{conn: conn} do
      conn =
        post_operations(conn, [
          cancel_operation("group-81"),
          payment_operation("group-81", 100, %{"operation_id" => "op-pay-after"}),
          reschedule_operation("group-81", "2026-12-20", %{"operation_id" => "op-move-after"}),
          cancel_operation("group-81", %{"operation_id" => "op-cancel-again"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "revisions" do
    test "each applied operation increments exactly once and rejections never do", %{conn: conn} do
      operations = [
        open_operation(),
        %{"operation_id" => "op-bad-type", "type" => "mystery", "group_id" => "group-81"},
        payment_operation("group-81", 1000),
        payment_operation("group-81", 999_999),
        reschedule_operation("group-81", "2026-12-11"),
        cancel_operation("group-81")
      ]

      revisions =
        conn
        |> post_operations(operations)
        |> json_response(200)
        |> Map.fetch!("results")

      assert Enum.map(revisions, &Map.get(&1, "revision")) == [1, nil, 2, nil, 3, 4]
    end

    test "an applied operation that changes nothing visible still increments", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          reschedule_operation("group-81", "2026-12-10")
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "new_arrival_on" => "2026-12-10", "revision" => 2}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "expected_revision" do
    test "applies when it matches the revision immediately before the operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000, %{"expected_revision" => 1})
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "amount_cents" => 1000, "revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "sees changes made by earlier operations in the same batch", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000),
          payment_operation("group-81", 1000, %{"expected_revision" => 2})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 3}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects stale revisions with the documented payload", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000, %{"expected_revision" => 5})
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-payment",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 5,
                 "actual_revision" => 1
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get_group(conn, "group-81") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 0}} = get_ledger(conn) |> json_response(200)
    end

    test "a stale revision is rejected before other domain rules apply", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_operation("group-81"),
          payment_operation("group-81", 999_999, %{
            "operation_id" => "op-stale-and-over",
            "expected_revision" => 1
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "stale_revision"}
             ] = json_response(conn, 200)["results"]
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      conn =
        post_operations(conn, [
          cancel_operation("ghost-group", %{"expected_revision" => 99})
        ])

      assert [
               %{"status" => "rejected", "code" => "group_not_found"}
             ] = json_response(conn, 200)["results"]
    end

    test "omitting expected_revision preserves unconditional behavior", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000),
          payment_operation("group-81", 1000, %{"operation_id" => "op-unaware"}),
          reschedule_operation("group-81", "2026-12-15")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3},
               %{"status" => "applied", "revision" => 4}
             ] = json_response(conn, 200)["results"]
    end

    test "open_group does not use expected_revision", %{conn: conn} do
      conn = post_operations(conn, [open_operation(%{"expected_revision" => 7})])

      assert [%{"status" => "applied", "revision" => 1}] = json_response(conn, 200)["results"]
    end
  end
end
