defmodule GroupStayWeb.Controllers.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  @occurred_on "2026-10-03"

  describe "room-level accounting" do
    test "exposes each room's deposit requirement and status", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation()])

      assert %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "active",
                   "deposit_due_cents" => 9_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500
             } = fetch_group!(conn, "group-81")
    end

    test "cash funds active rooms in original order, filling one room before the next", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000})
        ])

      assert %{"results" => [_, %{"outstanding_deposit_cents" => 9_500}]} =
               json_response(conn, 200)

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1_000}
               ],
               "cash_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500
             } = fetch_group!(conn, "group-81")
    end

    test "cash and credit fund rooms together in operation-processing order", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 4_000})
        ])

      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-81",
                "amount_cents" => 8_000
              })
            ]
        )

      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 7_500})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # The payment lands first: room-a keeps cash 4_000. The credit fills
      # room-a's remaining 5_000, then room-b's 3_000. The last cash payment
      # fills room-b's remaining 7_500.
      assert %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "cash_paid_cents" => 4_000,
                   "credit_paid_cents" => 5_000
                 },
                 %{
                   "room_id" => "room-b",
                   "cash_paid_cents" => 7_500,
                   "credit_paid_cents" => 3_000
                 }
               ],
               "deposit_paid_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             } = fetch_group!(conn, "group-81")

      assert %{"credit_liability_cents" => 11_000} = ledger(conn)
    end

    test "allocates recorded funding in commit order, regardless of occurred_on", %{conn: conn} do
      # The second-submitted payment carries an earlier occurred_on but still
      # funds the rooms after the first-submitted one.
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{
            "operation_id" => "op-first-submitted",
            "amount_cents" => 5_000
          }),
          record_payment_operation(%{
            "operation_id" => "op-second-submitted",
            "occurred_on" => "2026-09-01",
            "amount_cents" => 5_000
          })
        ])

      assert %{"results" => [_, _, _]} = json_response(conn, 200)

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1_000}
               ]
             } = fetch_group!(conn, "group-81")
    end

    test "allocates legacy funding as one unattributed senior block before durable funding", %{
      conn: conn
    } do
      conn = post_operations(conn, [open_group_operation()])
      group = Repo.get_by!(Group, group_id: "group-81")

      # Funding from before durable operation records existed: aggregate cash
      # and an unattributed hotel-credit application.
      Repo.insert!(%Entry{
        group_id: group.id,
        type: "cash_held",
        amount_cents: 10_000,
        occurred_on: ~D[2026-01-05],
        operation_id: "legacy-pay-1"
      })

      lot =
        Repo.insert!(%Lot{
          guest_id: "guest-22",
          source_operation_id: "legacy-cancel-1",
          remaining_cents: 300,
          expires_on: ~D[2028-01-06]
        })

      Repo.insert!(%Application{
        group_id: group.id,
        lot_id: lot.id,
        amount_cents: 3_000,
        operation_id: nil,
        room_id: nil
      })

      # Durable funding recorded afterward allocates only after the senior
      # block has filled the rooms in their original order.
      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-durable", "amount_cents" => 5_000})
        ])

      assert %{"results" => [%{"outstanding_deposit_cents" => 1_500}]} = json_response(conn, 200)

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9_000, "credit_paid_cents" => 0},
                 %{
                   "room_id" => "room-b",
                   "cash_paid_cents" => 6_000,
                   "credit_paid_cents" => 3_000
                 }
               ],
               "cash_paid_cents" => 15_000,
               "credit_paid_cents" => 3_000,
               "outstanding_deposit_cents" => 1_500
             } = fetch_group!(conn, "group-81")

      # Allocation changed no aggregate balance: the recorded cash is still
      # 15_000 held and the lot still carries its unapplied remainder.
      assert %{"cash_held_cents" => 15_000, "credit_liability_cents" => 3_300} = ledger(conn)

      assert %{"available_cents" => 300, "lots" => [%{"remaining_cents" => 300}]} =
               guest_credit(conn, "guest-22", "2028-01-05")
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves the others unchanged", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000}),
          cancel_rooms_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-26",
            "room_ids" => ["room-a"]
          })
        ])

      assert %{"results" => [_, _, cancellation]} = json_response(conn, 200)

      assert cancellation == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 9_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "status" => "active",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "cancelled",
                   "deposit_due_cents" => 0,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 1_000,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 52_500,
               "deposit_due_cents" => 10_500,
               "deposit_paid_cents" => 1_000,
               "outstanding_deposit_cents" => 9_500
             } = fetch_group!(conn, "group-81")

      assert %{"cash_refunded_cents" => 9_000, "cash_held_cents" => 1_000} = ledger(conn)
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      rooms = [
        %{"room_id" => "zebra", "nightly_rate_cents" => 9_000},
        %{"room_id" => "alpha", "nightly_rate_cents" => 9_000}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-order", "rooms" => rooms}),
          cancel_rooms_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-order",
            "room_ids" => ["alpha", "zebra"]
          })
        ])

      assert %{"results" => [_, %{"cancelled_room_ids" => ["zebra", "alpha"]}]} =
               json_response(conn, 200)
    end

    test "the unpaid deposit of the settled rooms ceases to be due", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_rooms_operation(%{"room_ids" => ["room-a"]})
        ])

      assert %{"results" => [_, %{"refunded_cents" => 0, "retained_cents" => 0}]} =
               json_response(conn, 200)

      assert %{
               "lodging_total_cents" => 52_500,
               "deposit_due_cents" => 10_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 10_500
             } = fetch_group!(conn, "group-81")
    end

    test "a non-refundable cancellation retains the selected rooms' cash", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000}),
          cancel_rooms_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-27",
            "room_ids" => ["room-a"]
          })
        ])

      assert %{"results" => [_, _, %{"refunded_cents" => 0, "retained_cents" => 9_000}]} =
               json_response(conn, 200)

      assert %{"cash_retained_cents" => 9_000, "cash_held_cents" => 1_000} = ledger(conn)

      # The group stays active and its remaining room can still be funded.
      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-4", "amount_cents" => 9_500})
        ])

      assert %{"results" => [%{"outstanding_deposit_cents" => 0}]} = json_response(conn, 200)
    end

    test "computes the hotel-credit bonus once on the selected rooms' combined cash", %{
      conn: conn
    } do
      # Two rooms whose deposits are 5_555 each; the combined settled cash is
      # 11_110, whose 10% bonus is exactly 1_111 once. Separate per-room
      # bonuses would round to 556 each and issue 12_222 instead.
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 27_775},
        %{"room_id" => "room-b", "nightly_rate_cents" => 27_775}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-bonus",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => rooms
          }),
          record_payment_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-bonus",
            "amount_cents" => 5_555
          }),
          record_payment_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-bonus",
            "amount_cents" => 5_555
          }),
          cancel_rooms_operation(%{
            "operation_id" => "op-4",
            "group_id" => "group-bonus",
            "occurred_on" => "2026-11-20",
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, _, %{"credit_issued_cents" => 12_221}]} =
               json_response(conn, 200)

      # Cancelling every active room cancels the group.
      assert %{"status" => "cancelled", "deposit_paid_cents" => 0} =
               fetch_group!(conn, "group-bonus")

      assert %{"cash_converted_to_credit_cents" => 11_110, "credit_liability_cents" => 12_221} =
               ledger(conn, on: "2027-11-20")
    end

    test "restores applied credit of refundably settled rooms to their lots", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 10_000
              }),
              cancel_rooms_operation(%{
                "operation_id" => "op-cancel-a",
                "group_id" => "group-target",
                "occurred_on" => "2026-11-26",
                "room_ids" => ["room-a"]
              })
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The credit spanned both rooms: room-a held 9_000 of it and returns it,
      # room-b keeps its 1_000.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "credit_paid_cents" => 0},
                 %{"room_id" => "room-b", "credit_paid_cents" => 1_000}
               ],
               "credit_paid_cents" => 1_000
             } = fetch_group!(conn, "group-target")

      assert %{"available_cents" => 10_000, "lots" => [%{"remaining_cents" => 10_000}]} =
               guest_credit(conn, "guest-22", "2027-11-20")

      assert %{"credit_liability_cents" => 11_000} = ledger(conn, on: "2027-11-20")
    end

    test "consumes applied credit when the selected rooms settle non-refundably", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 10_000
              }),
              cancel_rooms_operation(%{
                "operation_id" => "op-cancel-a",
                "group_id" => "group-target",
                "occurred_on" => "2026-11-27",
                "room_ids" => ["room-a"]
              })
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"available_cents" => 1_000} = guest_credit(conn, "guest-22", "2027-11-20")

      # The lot's unapplied 1_000 remains available and room-b still holds
      # 1_000 of applied credit; the consumed 9_000 left the liability.
      assert %{"credit_liability_cents" => 2_000} = ledger(conn, on: "2027-11-20")
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000}),
          cancel_rooms_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-26",
            "room_ids" => ["room-a"]
          }),
          cancel_operation(%{
            "operation_id" => "op-4",
            "occurred_on" => "2026-11-26"
          })
        ])

      assert %{"results" => [_, _, first, second]} = json_response(conn, 200)

      assert %{"refunded_cents" => 9_000, "retained_cents" => 0} = first
      assert %{"refunded_cents" => 1_000, "retained_cents" => 0, "revision" => 4} = second

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = fetch_group!(conn, "group-81")

      assert %{"cash_refunded_cents" => 10_000, "cash_held_cents" => 0} = ledger(conn)
    end

    test "cancelling the last active room makes the group cancelled", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_rooms_operation(%{"operation_id" => "op-2", "room_ids" => ["room-b"]}),
          cancel_rooms_operation(%{"operation_id" => "op-3", "room_ids" => ["room-a"]})
        ])

      assert %{"results" => [_, _, second]} = json_response(conn, 200)

      assert %{
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 3
             } = second

      assert %{"status" => "cancelled", "deposit_due_cents" => 0} = fetch_group!(conn, "group-81")

      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-4", "amount_cents" => 1_000})
        ])

      assert %{"results" => [%{"code" => "group_not_active"}]} = json_response(conn, 200)
    end

    test "rejects the complete operation unless every room id names a distinct active room", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_rooms_operation(%{"operation_id" => "op-2", "room_ids" => ["room-a"]})
        ])

      assert %{"results" => [_, first]} = json_response(conn, 200)
      assert first["status"] == "applied"

      room_ids = [
        ["room-a"],
        ["room-b", "room-b"],
        [],
        ["room-z"],
        ["room-a", "room-z"]
      ]

      for {room_ids_value, index} <- Enum.with_index(room_ids) do
        conn =
          post_operations(conn, [
            cancel_rooms_operation(%{
              "operation_id" => "op-invalid-#{index}",
              "room_ids" => room_ids_value
            })
          ])

        assert_rejected_at(conn, 0, "invalid_rooms")
      end

      for {room_ids_value, index} <-
            Enum.with_index([nil, "room-a", ["room-a", 42], [""]]) do
        conn =
          post_operations(conn, [
            cancel_rooms_operation(%{
              "operation_id" => "op-malformed-#{index}",
              "room_ids" => room_ids_value
            })
          ])

        assert_rejected_at(conn, 0, "invalid_rooms")
      end

      # Another group's room does not count either.
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "operation_id" => "op-open-other",
            "group_id" => "group-other",
            "rooms" => [%{"room_id" => "other-room", "nightly_rate_cents" => 9_000}]
          }),
          cancel_rooms_operation(%{
            "operation_id" => "op-cross",
            "group_id" => "group-other",
            "room_ids" => ["room-a"]
          })
        ])

      assert %{"results" => [_, %{"code" => "invalid_rooms"}]} = json_response(conn, 200)

      # None of the rejections advanced the revision.
      assert %{"revision" => 2} = fetch_group!(conn, "group-81")
    end

    test "rejects hotel credit for a non-refundable room settlement", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          cancel_rooms_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-27",
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, %{"code" => "refund_method_not_available"}]} =
               json_response(conn, 200)

      assert %{"status" => "active", "revision" => 2} = fetch_group!(conn, "group-81")
    end

    test "a stale revision is rejected before the room selection", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_rooms_operation(%{"room_ids" => ["room-a"], "expected_revision" => 7})
        ])

      assert %{"results" => [_, %{"code" => "stale_revision"}]} = json_response(conn, 200)
    end

    test "retries return the exact stored result", %{conn: conn} do
      op =
        cancel_rooms_operation(%{
          "operation_id" => "op-2",
          "occurred_on" => "2026-11-26",
          "room_ids" => ["room-b", "room-a"]
        })

      conn = post_operations(conn, [open_group_operation(), op])

      assert %{"results" => [_, first]} = json_response(conn, 200)

      conn = post_operations(conn, [op])
      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == first

      assert %{"revision" => 2} = fetch_group!(conn, "group-81")
      assert %{"cash_held_cents" => 0} = ledger(conn)
    end
  end

  defp cancel_rooms_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-25",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp convert_cash_to_credit(group_id, operation_id, cash_cents, occurred_on) do
    [
      open_group_operation(%{"group_id" => group_id, "operation_id" => operation_id <> "-open"}),
      record_payment_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id <> "-pay",
        "amount_cents" => cash_cents
      }),
      cancel_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ]
  end

  defp assert_rejected_at(conn, index, code) do
    assert %{"results" => results} = json_response(conn, 200)
    result = Enum.at(results, index)
    assert result["status"] == "rejected"
    assert result["code"] == code
  end

  defp ledger(conn, opts \\ []) do
    query = if on = opts[:on], do: "?on=#{on}", else: ""
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger#{query}"), 200)
    data
  end

  defp guest_credit(conn, guest_id, on) do
    assert %{"data" => data} =
             json_response(get(conn, "/api/v1/guests/#{guest_id}/credit?on=#{on}"), 200)

    data
  end
end
