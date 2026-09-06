defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo

  @issue_cancel_on "2026-11-20"
  # The last day the default flex-14 group cancels refundably.
  @refund_boundary "2026-11-26"
  # One day past the window: non-refundable.
  @late_cancel_on "2026-11-27"

  defp results(conn), do: conn |> json_response(200) |> Map.fetch!("results")

  defp group_data(conn, group_id) do
    conn |> get_group(group_id) |> json_response(200) |> Map.fetch!("data")
  end

  defp room(data, room_id), do: Enum.find(data["rooms"], &(&1["room_id"] == room_id))

  defp ledger_data(conn), do: conn |> get_ledger() |> json_response(200) |> Map.fetch!("data")

  defp guest_credit(conn, guest_id, on) do
    conn
    |> get_guest_credit(guest_id, on: on)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp statement(conn, payment_operation_id) do
    conn |> get_payment(payment_operation_id) |> json_response(200) |> Map.fetch!("data")
  end

  describe "room-level accounting" do
    test "cash fills each room's deposit before moving to the next room", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 10_000, %{"operation_id" => "op-pay-a"}),
          payment_operation("group-81", 5_000, %{"operation_id" => "op-pay-b"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
               results(conn)

      data = group_data(conn, "group-81")

      assert %{
               "lodging_cents" => 45_000,
               "status" => "active",
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0
             } = room(data, "room-a")

      assert %{
               "lodging_cents" => 52_500,
               "status" => "active",
               "deposit_due_cents" => 10_500,
               "cash_paid_cents" => 6_000,
               "credit_paid_cents" => 0
             } = room(data, "room-b")

      assert %{
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 15_000,
               "outstanding_deposit_cents" => 4_500,
               "cash_paid_cents" => 15_000,
               "credit_paid_cents" => 0
             } =
               Map.take(data, [
                 "lodging_total_cents",
                 "deposit_due_cents",
                 "deposit_paid_cents",
                 "outstanding_deposit_cents",
                 "cash_paid_cents",
                 "credit_paid_cents"
               ])
    end

    test "hotel credit continues filling beside cash in room order", %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "credit-group",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation("credit-group", 5_000, %{"occurred_on" => "2027-02-10"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      data = group_data(conn, "credit-group")

      # room-c's whole applied credit funds its deposit; no cash involved.
      assert %{"cash_paid_cents" => 0, "credit_paid_cents" => 5_000} = room(data, "room-c")

      # room-deposit 9000: 5000 paid by credit, 4000 outstanding.
      assert %{"deposit_paid_cents" => 5_000, "outstanding_deposit_cents" => 4_000} =
               Map.take(data, ["deposit_paid_cents", "outstanding_deposit_cents"])
    end

    test "funding allocates in commit order regardless of occurred_on", %{conn: conn} do
      # p1 commits first but carries the later date; the entitlement split on
      # conversion proves allocation followed commit order, not occurred_on.
      conn =
        post_operations(conn, [
          open_operation(%{"guest_id" => "order-guest"}),
          payment_operation("group-81", 9_000, %{
            "operation_id" => "op-commit-first",
            "occurred_on" => "2026-12-01"
          }),
          payment_operation("group-81", 10_500, %{
            "operation_id" => "op-commit-second",
            "occurred_on" => "2026-11-01"
          }),
          cancel_operation("group-81", %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "credit_issued_cents" => 21_450
               }
             ] = results(conn)

      # Commit-order entitlements: op-commit-first earned bonus(9000)=9900;
      # op-commit-second the 11550 remainder.
      conn = post_operations(conn, [charge_back_payment_operation("op-commit-first")])

      assert [%{"status" => "applied", "charged_back_cents" => 9_000}] = results(conn)

      assert %{"available_cents" => 11_550} = guest_credit(conn, "order-guest", "2026-11-21")
    end
  end

  describe "cancel_rooms" do
    test "settles every selected room and reports them in original order", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 10_000, %{"operation_id" => "op-pay"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results(conn)

      # Supplied out of order; the result follows the group's room order.
      conn =
        post_operations(conn, [
          cancel_rooms_operation("group-81", ["room-b", "room-a"], %{
            "operation_id" => "op-shrink"
          })
        ])

      assert [
               %{
                 "operation_id" => "op-shrink",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "refunded_cents" => 10_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = results(conn)

      data = group_data(conn, "group-81")

      assert Enum.all?(data["rooms"], &(&1["status"] == "cancelled"))
      assert Enum.all?(data["rooms"], &(&1["cash_paid_cents"] == 0))

      # A fully-settled group has no active rooms, so all money totals are zero.
      assert %{
               "status" => "cancelled",
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             } =
               Map.take(data, [
                 "status",
                 "lodging_total_cents",
                 "deposit_due_cents",
                 "deposit_paid_cents",
                 "outstanding_deposit_cents",
                 "cash_paid_cents",
                 "credit_paid_cents"
               ])

      # A cancelled room keeps its historical deposit requirement visible.
      assert %{"deposit_due_cents" => 9_000} = room(data, "room-a")

      assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 10_000} = ledger_data(conn)

      # The reconciliation view agrees with the settlement.
      assert %{
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             } = statement(conn, "op-pay")
    end

    test "other rooms and their allocations are untouched by a partial settlement", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 10_000, %{"operation_id" => "op-pay"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results(conn)

      conn =
        post_operations(conn, [
          cancel_rooms_operation("group-81", ["room-b"], %{"occurred_on" => @refund_boundary})
        ])

      assert [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 1_000
               }
             ] = results(conn)

      data = group_data(conn, "group-81")

      assert %{"status" => "active", "revision" => 3} = data

      # room-a keeps its 9000 of held cash; only room-b's 1000 was refunded.
      assert %{"status" => "active", "cash_paid_cents" => 9_000} = room(data, "room-a")
      assert %{"status" => "cancelled", "cash_paid_cents" => 0} = room(data, "room-b")

      assert %{"deposit_due_cents" => 9_000, "outstanding_deposit_cents" => 0} =
               Map.take(data, ["deposit_due_cents", "outstanding_deposit_cents"])

      assert %{"cash_held_cents" => 9_000, "cash_refunded_cents" => 1_000} = ledger_data(conn)

      assert %{"held_cents" => 9_000, "refunded_cents" => 1_000} =
               Map.take(statement(conn, "op-pay"), ["held_cents", "refunded_cents"])
    end

    test "unpaid deposit for cancelled rooms ceases to be due and later funding flows to the rest",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_rooms_operation("group-81", ["room-a"], %{"occurred_on" => @refund_boundary})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied", "refunded_cents" => 0}] =
               results(conn)

      assert %{
               "status" => "active",
               "deposit_due_cents" => 10_500,
               "outstanding_deposit_cents" => 10_500
             } =
               Map.take(group_data(conn, "group-81"), [
                 "status",
                 "deposit_due_cents",
                 "outstanding_deposit_cents"
               ])

      conn = post_operations(conn, [payment_operation("group-81", 10_500)])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0}] = results(conn)
    end

    test "computes the hotel-credit bonus once over the selected rooms' combined cash", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(%{"guest_id" => "combine-guest"}),
          payment_operation("group-81", 4_000, %{"operation_id" => "op-p1"}),
          payment_operation("group-81", 8_000, %{"operation_id" => "op-p2"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          cancel_rooms_operation("group-81", ["room-a", "room-b"], %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      # Combined cash 12000 converts once into one 13200 lot — never 110%
      # per room.
      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 13_200,
                 "revision" => 4
               }
             ] = results(conn)

      # Telescoping entitlements: p1 earned bonus(4000)=4400, p2 the 8800 rest.
      conn = post_operations(conn, [charge_back_payment_operation("op-p1")])
      assert [%{"status" => "applied", "charged_back_cents" => 4_000}] = results(conn)

      assert %{"available_cents" => 8_800} = guest_credit(conn, "combine-guest", "2026-11-21")

      conn = post_operations(conn, [charge_back_payment_operation("op-p2")])
      assert [%{"status" => "applied", "charged_back_cents" => 8_000}] = results(conn)

      assert %{"available_cents" => 0} = guest_credit(conn, "combine-guest", "2026-11-21")

      assert %{"cash_converted_to_credit_cents" => 0, "cash_charged_back_cents" => 12_000} =
               ledger_data(conn)
    end

    test "a refundable partial cancellation restores applied credit to its lots", %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "mixed-group",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-m", "nightly_rate_cents" => 12_000}]
          }),
          apply_credit_operation("mixed-group", 5_000, %{"occurred_on" => "2027-02-10"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          cancel_rooms_operation("mixed-group", ["room-m"], %{
            # Within the flex-14 window of the default stay, so the applied
            # credit is restored rather than consumed.
            "occurred_on" => @issue_cancel_on
          })
        ])

      assert [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-m"],
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = results(conn)

      # The 5000 went back to its original lot with its original expiry.
      assert %{
               "available_cents" => 6_600,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-standard",
                   "remaining_cents" => 6_600,
                   "expires_on" => "2027-11-21"
                 }
               ]
             } = guest_credit(conn, "guest-22", @issue_cancel_on)
    end

    test "a non-refundable partial cancellation retains selected rooms' cash", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 12_000)
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          cancel_rooms_operation("group-81", ["room-a"], %{"occurred_on" => @late_cancel_on})
        ])

      assert [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 0,
                 "retained_cents" => 9_000,
                 "credit_issued_cents" => 0
               }
             ] = results(conn)

      assert %{"cash_retained_cents" => 9_000, "cash_held_cents" => 3_000} = ledger_data(conn)
    end

    test "cancelling the final active room closes the whole group", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_rooms_operation("group-81", ["room-a"], %{"occurred_on" => @refund_boundary}),
          cancel_rooms_operation("group-81", ["room-b"], %{
            "operation_id" => "op-last-room",
            "occurred_on" => @refund_boundary
          }),
          payment_operation("group-81", 100),
          cancel_rooms_operation("group-81", ["room-b"], %{"occurred_on" => @refund_boundary}),
          cancel_operation("group-81", %{"occurred_on" => @refund_boundary})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 3},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = results(conn)

      assert %{"status" => "cancelled"} = Map.take(group_data(conn, "group-81"), ["status"])
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          # 12000 funds room-a fully (9000) and room-b partially (3000).
          payment_operation("group-81", 12_000),
          # Refundably settles room-a's 9000.
          cancel_rooms_operation("group-81", ["room-a"], %{
            "occurred_on" => @refund_boundary,
            "operation_id" => "op-shrink-first"
          }),
          # A later full cancellation touches only room-b's 3000.
          cancel_operation("group-81", %{
            "operation_id" => "op-final-cancel",
            "occurred_on" => @late_cancel_on
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 9_000},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 3_000,
                 "revision" => 4
               }
             ] = results(conn)

      assert %{"status" => "cancelled", "cash_paid_cents" => 0} =
               Map.take(group_data(conn, "group-81"), ["status", "cash_paid_cents"])

      assert %{"cash_refunded_cents" => 9_000, "cash_retained_cents" => 3_000} =
               ledger_data(conn)
    end

    test "rejects the complete operation unless every id names a distinct active room of the group",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "other-group",
            "rooms" => [%{"room_id" => "room-other", "nightly_rate_cents" => 15_000}]
          }),
          cancel_rooms_operation("group-81", ["room-b", "room-b"]),
          cancel_rooms_operation("group-81", ["room-zzz"]),
          cancel_rooms_operation("group-81", ["room-other"]),
          cancel_rooms_operation("group-81", []),
          cancel_rooms_operation("group-81", ["room-b", "room-zzz"]),
          cancel_rooms_operation("group-81", "room-b"),
          cancel_rooms_operation("group-81", nil),
          cancel_rooms_operation("group-81", [123])
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_operation"},
               %{"status" => "rejected", "code" => "invalid_operation"},
               %{"status" => "rejected", "code" => "invalid_rooms"}
             ] = results(conn)

      # Nothing settled anywhere: both groups are untouched at revision 1.
      assert %{"status" => "active", "revision" => 1, "cash_paid_cents" => 0} =
               Map.take(group_data(conn, "group-81"), ["status", "revision", "cash_paid_cents"])

      assert %{"status" => "active", "revision" => 1} =
               Map.take(group_data(conn, "other-group"), ["status", "revision"])
    end

    test "already-cancelled rooms cannot be selected again", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_rooms_operation("group-81", ["room-a"], %{"occurred_on" => @refund_boundary}),
          cancel_rooms_operation("group-81", ["room-a", "room-zzz"], %{
            "operation_id" => "op-second-time",
            "occurred_on" => @refund_boundary
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_rooms"}
             ] = results(conn)

      assert %{"status" => "active", "revision" => 2} =
               Map.take(group_data(conn, "group-81"), ["status", "revision"])
    end

    test "checks the revision before the room rules when the group exists", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_rooms_operation("ghost-group", ["room-a"], %{"expected_revision" => 3}),
          cancel_rooms_operation("group-81", [], %{
            "operation_id" => "op-stale-and-empty",
            "expected_revision" => 7,
            "occurred_on" => @refund_boundary
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_found"},
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 7,
                 "actual_revision" => 1
               }
             ] = results(conn)
    end

    test "is durably idempotent like every other operation", %{conn: conn} do
      operation =
        cancel_rooms_operation("group-81", ["room-b"], %{
          "operation_id" => "op-idempotent-shrink",
          "occurred_on" => @refund_boundary
        })

      conn = post_operations(conn, [open_operation(), operation])

      assert [_open, first] = results(conn)
      assert %{"status" => "applied", "refunded_cents" => 0, "revision" => 2} = first

      retry = post_operations(conn, [operation]) |> results() |> hd()
      assert retry == first

      # The replay settled nothing further: room-a is still active at the
      # same revision.
      data = group_data(conn, "group-81")

      assert %{"status" => "active", "deposit_due_cents" => 9_000} =
               Map.take(room(data, "room-a"), [
                 "status",
                 "deposit_due_cents"
               ])

      assert %{"status" => "cancelled"} = Map.take(room(data, "room-b"), ["status"])
      assert %{"revision" => 2} = Map.take(data, ["revision"])

      variant =
        post_operations(conn, [
          cancel_rooms_operation("group-81", ["room-a"], %{
            "operation_id" => "op-idempotent-shrink",
            "occurred_on" => @refund_boundary
          })
        ])
        |> results()
        |> hd()

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = variant
    end
  end

  describe "legacy funding brought forward as one unattributed senior block" do
    test "the migration seeds aggregate cash then credit lots in consumption order, ahead of durable funding",
         %{conn: conn} do
      seed_legacy_fixture()

      # A durable payment committed now must land AFTER the senior block:
      # legacy cash filled legacy-a entirely and the legacy credit sits on
      # legacy-b, so this payment tops up legacy-b's remaining capacity.
      conn =
        post_operations(conn, [
          payment_operation("legacy-group", 5_500, %{
            "operation_id" => "op-durable-after-legacy",
            "occurred_on" => "2026-10-01"
          })
        ])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0}] = results(conn)

      data = group_data(conn, "legacy-group")

      assert %{
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0
             } = room(data, "legacy-a")

      # Aggregate cash 12000 filled legacy-a (9000) and spilled 3000 onto
      # legacy-b before the 2000 credit lot and the durable 5500.
      assert %{
               "deposit_due_cents" => 10_500,
               "cash_paid_cents" => 8_500,
               "credit_paid_cents" => 2_000
             } = room(data, "legacy-b")

      # A group cancelled before this release keeps every room cancelled
      # with nothing held or due.
      dead = group_data(conn, "dead-legacy-group")

      assert %{"status" => "cancelled", "deposit_due_cents" => 0, "cash_paid_cents" => 0} =
               Map.take(dead, ["status", "deposit_due_cents", "cash_paid_cents"])

      assert Enum.all?(dead["rooms"], &(&1["status"] == "cancelled"))

      # Settling legacy-b converts its combined cash — the unattributed 3000
      # senior slice plus the durable 5500 — into one lot worth bonus(8500).
      conn =
        post_operations(conn, [
          cancel_rooms_operation("legacy-group", ["legacy-b"], %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 9_350}] =
               results(conn)

      # The durable entitlement runs from the senior block's baseline:
      # bonus(8500) - bonus(3000) = 6050. Charging the payment back revokes
      # exactly that share, leaving bonus(3000) = 3300 in the lot.
      conn = post_operations(conn, [charge_back_payment_operation("op-durable-after-legacy")])

      assert [%{"status" => "applied", "charged_back_cents" => 5_500}] = results(conn)

      # Settling legacy-b also restored its 2000 of legacy credit onto the
      # ancient lot (4600 + 2000), and the chargeback left bonus(3000) = 3300
      # of the settlement lot.
      assert %{
               "available_cents" => 9_900,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-ancient",
                   "remaining_cents" => 6_600
                 },
                 %{
                   "remaining_cents" => 3_300
                 }
               ]
             } = guest_credit(conn, "legacy-guest", "2026-11-21")

      # Only the durable slice's classification moved to charged-back cash;
      # the unattributed portion stays converted history.
      assert %{"cash_charged_back_cents" => 5_500, "cash_converted_to_credit_cents" => 3_000} =
               ledger_data(conn)

      assert %{
               "recorded_cents" => 5_500,
               "held_cents" => 0,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 5_500,
               "reduced_cents" => 0
             } =
               Map.take(statement(conn, "op-durable-after-legacy"), [
                 "recorded_cents",
                 "held_cents",
                 "converted_to_credit_cents",
                 "charged_back_cents",
                 "reduced_cents"
               ])
    end
  end

  # Seeds what a release-03 database looked like just before this release's
  # migration ran: no room statuses/deposit requirements computed, funding
  # without durable operation records. Then runs the shipped backfill.
  defp seed_legacy_fixture do
    ts = "2026-08-01T00:00:00Z"

    insert_group = fn group_id, guest_id, revision, status, booked_on, arrival, departure, due ->
      Repo.query!(
        """
        INSERT INTO groups
          (group_id, guest_id, property_id, revision, status, rate_plan, policy_version,
           booked_on, arrival_on, departure_on, deposit_due_cents, inserted_at, updated_at)
        VALUES (?, ?, 'ams-canal', ?, ?, 'flexible', 'flex-14', ?, ?, ?, ?, ?, ?)
        """,
        [group_id, guest_id, revision, status, booked_on, arrival, departure, due, ts, ts]
      )
    end

    insert_room = fn group_id, position, room_id, rate ->
      Repo.query!(
        """
        INSERT INTO rooms (group_id, position, room_id, nightly_rate_cents, inserted_at, updated_at)
        SELECT id, ?, ?, ?, ?, ? FROM groups WHERE group_id = ?
        """,
        [position, room_id, rate, ts, ts, group_id]
      )
    end

    insert_payment = fn group_id, amount ->
      Repo.query!(
        """
        INSERT INTO ledger_entries (group_id, kind, amount_cents, operation_id, inserted_at, updated_at)
        SELECT id, 'payment', ?, NULL, ?, ? FROM groups WHERE group_id = ?
        """,
        [amount, ts, ts, group_id]
      )
    end

    insert_group.(
      "legacy-group",
      "legacy-guest",
      3,
      "active",
      "2026-10-03",
      "2026-12-10",
      "2026-12-13",
      19_500
    )

    insert_group.(
      "dead-legacy-group",
      "old-guest",
      2,
      "cancelled",
      "2026-09-01",
      "2026-11-01",
      "2026-11-04",
      9_000
    )

    insert_room.("legacy-group", 0, "legacy-a", 15_000)
    insert_room.("legacy-group", 1, "legacy-b", 17_500)
    insert_room.("dead-legacy-group", 0, "dead-room", 15_000)

    # Funding predating durable operation records.
    insert_payment.("legacy-group", 4_000)
    insert_payment.("legacy-group", 8_000)
    insert_payment.("dead-legacy-group", 6_000)

    # The ancient lot issued 6600; 2000 was applied to the group, leaving
    # 4600 available while the old-world funding link holds the rest.
    Repo.query!(
      """
      INSERT INTO credit_lots
        (guest_id, source_operation_id, remaining_cents, expires_on, inserted_at, updated_at)
      VALUES ('legacy-guest', 'op-cancel-ancient', 4600, '2027-11-21', ?, ?)
      """,
      [ts, ts]
    )

    Repo.query!(
      """
      INSERT INTO credit_fundings (group_id, credit_lot_id, amount_cents, inserted_at, updated_at)
      SELECT (SELECT id FROM groups WHERE group_id = 'legacy-group'),
             (SELECT id FROM credit_lots WHERE source_operation_id = 'op-cancel-ancient'),
             2000, ?1, ?1
      """,
      [ts]
    )

    # The boot-time migrator compiles this file only when it actually has a
    # pending migration to run, so against an already-migrated test database
    # the module may not be loaded yet. Load it explicitly before rerunning
    # just its backfill inside the sandbox to bring the seeded pre-release
    # rows forward.
    migration_module = GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections

    unless Code.ensure_loaded?(migration_module) do
      path =
        "../../../priv/repo/migrations/20260825000004_add_room_accounting_and_payment_corrections.exs"
        |> Path.expand(__DIR__)

      Code.compile_file(path)
    end

    # Dispatched dynamically: the migration module is not part of the
    # compiled application, so a direct call cannot resolve at compile time.
    :ok = apply(migration_module, :backfill_room_accounting, [])
  end

  # Issues one 6600-cent credit lot for guest-22 via a refundable
  # hotel-credit cancellation of the standard fixture group.
  defp issue_standard_lot(conn) do
    conn =
      post_operations(conn, [
        open_operation(),
        payment_operation("group-81", 6000),
        cancel_operation("group-81", %{
          "operation_id" => "op-cancel-standard",
          "occurred_on" => @issue_cancel_on,
          "refund_method" => "hotel_credit"
        })
      ])

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"status" => "applied", "credit_issued_cents" => 6600}
           ] = results(conn)

    conn
  end
end
