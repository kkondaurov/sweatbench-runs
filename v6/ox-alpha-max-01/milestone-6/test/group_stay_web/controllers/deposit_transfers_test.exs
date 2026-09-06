defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo

  @issue_cancel_on "2026-11-20"
  # The last day the default flex-14 group cancels refundably.
  @refund_boundary "2026-11-26"

  defp results(conn), do: conn |> json_response(200) |> Map.fetch!("results")

  defp group_data(conn, group_id) do
    conn |> get_group(group_id) |> json_response(200) |> Map.fetch!("data")
  end

  defp room(data, room_id), do: Enum.find(data["rooms"], &(&1["room_id"] == room_id))

  defp ledger_data(conn), do: conn |> get_ledger() |> json_response(200) |> Map.fetch!("data")

  defp statement(conn, payment_operation_id),
    do: conn |> get_payment(payment_operation_id) |> json_response(200) |> Map.fetch!("data")

  defp guest_credit(conn, guest_id, on) do
    conn
    |> get_guest_credit(guest_id, on: on)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Destination fixture: two flexible rooms worth 8000 deposit each, so the
  # outstanding deposit is 16000 and transfers can split across both rooms.
  defp open_destination(overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "group_id" => "group-b",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-22",
          "rooms" => [
            %{"room_id" => "room-c", "nightly_rate_cents" => 20_000},
            %{"room_id" => "room-d", "nightly_rate_cents" => 20_000}
          ]
        },
        overrides
      )
    )
  end

  describe "moving held funding" do
    test "moves cash between same-guest groups without touching any ledger total", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 5_000)
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      ledger_before = ledger_data(conn)

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 3_000, %{"operation_id" => "op-t"})
        ])

      assert [
               %{
                 "operation_id" => "op-t",
                 "status" => "applied",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-b",
                 "amount_cents" => 3_000,
                 "source_outstanding_deposit_cents" => 17_500,
                 "destination_outstanding_deposit_cents" => 13_000,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = results(conn)

      # The source's room-a gave up 3000; the destination's first room took it.
      source = group_data(conn, "group-81")
      assert %{"cash_paid_cents" => 2_000} = room(source, "room-a")
      assert %{"cash_paid_cents" => 0} = room(source, "room-b")

      destination = group_data(conn, "group-b")
      assert %{"cash_paid_cents" => 3_000, "credit_paid_cents" => 0} = room(destination, "room-c")
      assert %{"cash_paid_cents" => 0} = room(destination, "room-d")

      assert %{
               "outstanding_deposit_cents" => 17_500,
               "deposit_paid_cents" => 2_000,
               "revision" => 3
             } =
               Map.take(source, ["outstanding_deposit_cents", "deposit_paid_cents", "revision"])

      assert %{"outstanding_deposit_cents" => 13_000, "revision" => 2} =
               Map.take(destination, ["outstanding_deposit_cents", "revision"])

      # A transfer only changes which rooms hold the funding.
      assert ledger_data(conn) == ledger_before
    end

    test "draws the source in reverse allocation order and fills the destination in room order",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          # p1 fills 6000 of room-a; p2 fills room-a's last 3000 and 10000 of
          # room-b. Allocation order: [p1:a6000, p2:a3000, p2:b10000].
          payment_operation("group-81", 6_000, %{"operation_id" => "op-p1"}),
          payment_operation("group-81", 13_000, %{"operation_id" => "op-p2"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 11_500)
        ])

      # The draw takes the newest allocations first: room-b's 10000, then
      # 1500 back out of room-a — all of it p2's cash. The destination fills
      # room-c (8000) before room-d, keeping draw order across the split.
      assert [%{"status" => "applied", "amount_cents" => 11_500}] = results(conn)

      source = group_data(conn, "group-81")
      assert %{"cash_paid_cents" => 7_500} = room(source, "room-a")
      # p2's entire room-b allocation was drawn out.
      assert %{"cash_paid_cents" => 0} = room(source, "room-b")

      destination = group_data(conn, "group-b")
      assert %{"cash_paid_cents" => 8_000} = room(destination, "room-c")
      assert %{"cash_paid_cents" => 3_500} = room(destination, "room-d")

      # p2 moved with its identity intact; what remains of it is reported
      # per holding group in group-id order and sums to held_cents. p1 never
      # participated in a transfer and keeps the earlier statement shape.
      assert %{
               "held_cents" => 13_000,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 1_500},
                 %{"group_id" => "group-b", "amount_cents" => 11_500}
               ]
             } = Map.take(statement(conn, "op-p2"), ["held_cents", "held_by_group"])

      refute Map.has_key?(statement(conn, "op-p1"), "held_by_group")
    end

    test "transferred cash settles under the destination policy with the bonus computed there",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(%{
            "group_id" => "conv-group",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-23",
            "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}]
          }),
          payment_operation("conv-group", 1_000, %{"operation_id" => "op-native"}),
          payment_operation("group-81", 4_000, %{"operation_id" => "op-main"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "conv-group", 2_500)
        ])

      assert [%{"status" => "applied"}] = results(conn)

      # Refundable hotel-credit cancellation converts the combined cash once:
      # native 1000 plus transferred 2500 becomes a bonus(3500) = 3850 lot.
      conn =
        post_operations(conn, [
          cancel_operation("conv-group", %{
            "occurred_on" => "2026-12-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 3_850
               }
             ] = results(conn)

      # Provenance survived the move, so each payment revokes exactly its own
      # telescoping share: op-native earned bonus(1000)=1100, op-main the rest.
      conn = post_operations(conn, [charge_back_payment_operation("op-native")])
      assert [%{"status" => "applied"}] = results(conn)

      assert %{"available_cents" => 2_750} = guest_credit(conn, "guest-22", "2026-12-02")

      conn = post_operations(conn, [charge_back_payment_operation("op-main")])
      assert [%{"status" => "applied"}] = results(conn)

      assert %{"available_cents" => 0} = guest_credit(conn, "guest-22", "2026-12-02")
    end

    test "transferred credit keeps its lot, stays expiry-paused, and restores without another bonus",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{"group_id" => "src-group"}),
          payment_operation("src-group", 6_000),
          cancel_operation("src-group", %{
            "operation_id" => "op-cancel-src",
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "credit_issued_cents" => 6_600}
             ] = results(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "mid-group",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-22",
            "rooms" => [%{"room_id" => "room-m", "nightly_rate_cents" => 20_000}]
          }),
          apply_credit_operation("mid-group", 6_600),
          open_operation(%{
            "group_id" => "final-group",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-22",
            "rooms" => [%{"room_id" => "room-f", "nightly_rate_cents" => 20_000}]
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("mid-group", "final-group", 4_600)
        ])

      # The source reopens to 8000 - 2000; the destination owes 8000 - 4600.
      assert [
               %{
                 "status" => "applied",
                 "source_outstanding_deposit_cents" => 6_000,
                 "destination_outstanding_deposit_cents" => 3_400
               }
             ] = results(conn)

      mid = group_data(conn, "mid-group")
      assert %{"credit_paid_cents" => 2_000, "cash_paid_cents" => 0} = room(mid, "room-m")

      final = group_data(conn, "final-group")
      assert %{"credit_paid_cents" => 4_600, "cash_paid_cents" => 0} = room(final, "room-f")

      # A later refundable cancellation of the destination restores the moved
      # credit onto its original lot with its original expiry — no second
      # bonus and no new lot.
      conn =
        post_operations(conn, [
          cancel_operation("final-group", %{"occurred_on" => "2026-12-06"})
        ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = results(conn)

      assert %{
               "available_cents" => 4_600,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-src",
                   "remaining_cents" => 4_600,
                   "expires_on" => "2027-11-21"
                 }
               ]
             } = guest_credit(conn, "guest-22", "2026-12-06")

      # The middle group still holds its slice applied with expiry paused.
      assert %{"status" => "active", "credit_paid_cents" => 2_000} =
               Map.take(group_data(conn, "mid-group"), ["status", "credit_paid_cents"])
    end

    test "the unattributed legacy block moves like any other funding", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination()
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Seed an unattributed pre-release funding slice onto room-a, ahead of
      # anything durable.
      Repo.query!(
        """
        INSERT INTO room_fundings
          (group_id, room_id, kind, operation_id, credit_lot_id, amount_cents, inserted_at, updated_at)
        SELECT g.id, r.id, 'cash', NULL, NULL, 1234, ?1, ?1
        FROM groups g JOIN rooms r ON r.group_id = g.id AND r.room_id = 'room-a'
        WHERE g.group_id = 'group-81'
        """,
        ["2026-08-01T00:00:00Z"]
      )

      conn =
        post_operations(conn, [
          payment_operation("group-81", 2_000, %{"operation_id" => "op-p"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      # Reverse allocation order draws the durable 2000 first, then 1000 of
      # the legacy slice.
      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 3_000)
        ])

      assert [%{"status" => "applied"}] = results(conn)

      source = group_data(conn, "group-81")
      assert %{"cash_paid_cents" => 234} = room(source, "room-a")

      destination = group_data(conn, "group-b")
      assert %{"cash_paid_cents" => 3_000} = room(destination, "room-c")

      # A non-refundable settlement of the destination retains both slices
      # (2026-12-10 is past its flex-14 window of 2026-12-06); the
      # transferred payment reports nothing held anymore.
      conn =
        post_operations(conn, [
          cancel_operation("group-b", %{"occurred_on" => "2026-12-10"})
        ])

      assert [%{"status" => "applied", "retained_cents" => 3_000}] = results(conn)

      assert %{
               "held_cents" => 0,
               "retained_cents" => 2_000,
               "held_by_group" => []
             } = statement(conn, "op-p")

      assert %{"cash_retained_cents" => 3_000} = ledger_data(conn)
    end
  end

  describe "revisions across groups" do
    test "a reduction spanning groups bumps every changed group plus the addressed one", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 8_000, %{"operation_id" => "op-target"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 3_000)
        ])

      assert [%{"status" => "applied"}] = results(conn)

      # The reduction eats the transferred slice on group-b first.
      conn =
        post_operations(conn, [
          reduce_cash_payment_operation("op-target", 3_000, %{"operation_id" => "op-cut"})
        ])

      assert [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "op-target",
                 "group_id" => "group-81",
                 "amount_cents" => 3_000,
                 "outstanding_deposit_cents" => 14_500,
                 # The addressed original payment group's revision.
                 "revision" => 4
               }
             ] = results(conn)

      # Both groups advanced: group-81 as the addressed group, group-b
      # because its funding changed.
      assert %{"revision" => 4} = Map.take(group_data(conn, "group-81"), ["revision"])
      assert %{"revision" => 3} = Map.take(group_data(conn, "group-b"), ["revision"])

      # Only group-81 still holds target cash, so group-b drops out of the
      # per-group list while it stays present for a participating payment.
      assert %{
               "held_cents" => 5_000,
               "reduced_cents" => 3_000,
               "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 5_000}]
             } =
               Map.take(statement(conn, "op-target"), [
                 "held_cents",
                 "reduced_cents",
                 "held_by_group"
               ])
    end

    test "a chargeback spanning groups bumps every group whose funding moved", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 8_000, %{"operation_id" => "op-target"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 3_000)
        ])

      assert [%{"status" => "applied"}] = results(conn)

      conn =
        post_operations(conn, [
          charge_back_payment_operation("op-target", %{"operation_id" => "op-cb"})
        ])

      assert [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 8_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 4
               }
             ] = results(conn)

      assert %{"revision" => 4} = Map.take(group_data(conn, "group-81"), ["revision"])
      assert %{"revision" => 3} = Map.take(group_data(conn, "group-b"), ["revision"])

      assert %{"cash_paid_cents" => 0} = room(group_data(conn, "group-81"), "room-a")
      assert %{"cash_paid_cents" => 0} = room(group_data(conn, "group-b"), "room-c")

      assert %{"charged_back_cents" => 8_000, "held_by_group" => []} =
               Map.take(statement(conn, "op-target"), ["charged_back_cents", "held_by_group"])
    end

    test "the addressed group advances even when a correction only touches other groups", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 5_000, %{"operation_id" => "op-target"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Everything this payment holds now sits on the destination.
      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 5_000)
        ])

      assert [%{"status" => "applied"}] = results(conn)

      conn =
        post_operations(conn, [
          reduce_cash_payment_operation("op-target", 2_000)
        ])

      assert [%{"status" => "applied", "group_id" => "group-81", "revision" => 4}] =
               results(conn)

      # The untouched original group still advanced as the addressed group.
      assert %{"revision" => 4, "cash_paid_cents" => 0} =
               Map.take(group_data(conn, "group-81"), ["revision", "cash_paid_cents"])

      assert %{"revision" => 3} = Map.take(group_data(conn, "group-b"), ["revision"])
    end
  end

  describe "payment statement evolution" do
    test "held_by_group lists every holding group ordered by group id and sums to held_cents", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          open_destination(%{"group_id" => "group-z"}),
          payment_operation("group-81", 10_000, %{"operation_id" => "op-target"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-z", 4_000),
          transfer_deposit_operation("group-81", "group-b", 3_500)
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      data = statement(conn, "op-target")

      assert %{
               "held_cents" => 10_000,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 2_500},
                 %{"group_id" => "group-b", "amount_cents" => 3_500},
                 %{"group_id" => "group-z", "amount_cents" => 4_000}
               ]
             } = Map.take(data, ["held_cents", "held_by_group"])

      sum =
        data["held_by_group"]
        |> Enum.map(& &1["amount_cents"])
        |> Enum.sum()

      assert sum == data["held_cents"]
    end

    test "payments that never participated keep the earlier statement shape", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 2_000, %{"operation_id" => "op-quiet"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      data = statement(conn, "op-quiet")

      refute Map.has_key?(data, "held_by_group")

      assert %{
               "payment_operation_id" => "op-quiet",
               "original_group_id" => "group-81",
               "recorded_cents" => 2_000,
               "held_cents" => 2_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             } = data
    end
  end

  describe "transfer rejections" do
    test "missing groups are named by group_not_found before revisions or rules", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination()
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("ghost-source", "group-b", 100, %{"operation_id" => "op-s"}),
          transfer_deposit_operation("group-81", "ghost-dest", 100, %{
            "operation_id" => "op-d",
            "expected_revision" => 99
          })
        ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "ghost-source"
               },
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "ghost-dest"
               }
             ] = results(conn)
    end

    test "checks the source revision, then the destination revision", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination()
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 100, %{
            "operation_id" => "op-stale-src",
            "expected_revision" => 5
          }),
          transfer_deposit_operation("group-81", "group-b", 100, %{
            "operation_id" => "op-stale-dst",
            "destination_expected_revision" => 7
          }),
          transfer_deposit_operation("group-81", "group-b", 100, %{
            "operation_id" => "op-stale-both",
            "expected_revision" => 5,
            "destination_expected_revision" => 7
          })
        ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 5,
                 "actual_revision" => 1
               },
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-b",
                 "expected_revision" => 7,
                 "actual_revision" => 1
               },
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 5,
                 "actual_revision" => 1
               }
             ] = results(conn)
    end

    test "revision guards precede the transfer rules", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_operation("group-81", %{"occurred_on" => @refund_boundary})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Stale beats inactive...
      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-81", 100, %{
            "operation_id" => "op-stale-wins",
            "expected_revision" => 9
          })
        ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 9,
                 "actual_revision" => 2
               }
             ] = results(conn)

      # ...and a stale destination revision beats the same-group rule.
      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "fresh-group",
            "arrival_on" => "2027-01-10",
            "departure_on" => "2027-01-12",
            "rooms" => [%{"room_id" => "room-f", "nightly_rate_cents" => 10_000}]
          }),
          transfer_deposit_operation("fresh-group", "fresh-group", 100, %{
            "operation_id" => "op-dst-stale-wins",
            "destination_expected_revision" => 9
          })
        ])

      assert [
               _open,
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "fresh-group",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
             ] = results(conn)
    end

    test "invalid_transfer rejects the same group or different guests", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(%{"guest_id" => "someone-else"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-81", 100, %{"operation_id" => "op-same"}),
          transfer_deposit_operation("group-81", "group-b", 100, %{"operation_id" => "op-guest"})
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_transfer"},
               %{"status" => "rejected", "code" => "invalid_transfer"}
             ] = results(conn)
    end

    test "group_not_active names whichever group is not active", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(%{"group_id" => "group-c"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          cancel_operation("group-81", %{"occurred_on" => @refund_boundary}),
          cancel_operation("group-c", %{"occurred_on" => @refund_boundary})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-c", 100, %{
            "operation_id" => "op-src-dead"
          }),
          transfer_deposit_operation("group-c", "group-81", 100, %{
            "operation_id" => "op-dst-dead"
          })
        ])

      assert [
               %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"},
               %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-c"}
             ] = results(conn)
    end

    test "invalid_amount rejects unusable amounts after the group checks", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination()
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 0, %{"operation_id" => "op-zero"}),
          transfer_deposit_operation("group-81", "group-b", -5, %{"operation_id" => "op-neg"}),
          transfer_deposit_operation("group-81", "group-b", "5", %{"operation_id" => "op-str"}),
          transfer_deposit_operation("group-81", "group-b", nil, %{"operation_id" => "op-nil"})
        ])

      for result <- results(conn) do
        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end

      # Nothing moved anywhere.
      assert %{"cash_held_cents" => 0} = ledger_data(conn)
      assert %{"revision" => 1} = Map.take(group_data(conn, "group-81"), ["revision"])
      assert %{"revision" => 1} = Map.take(group_data(conn, "group-b"), ["revision"])
    end

    test "transfer_exceeds_held_funding when the source holds less than requested", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 2_000)
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [transfer_deposit_operation("group-81", "group-b", 2_001)])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}] =
               results(conn)

      assert %{"cash_held_cents" => 2_000} = ledger_data(conn)
    end

    test "transfer_exceeds_outstanding when the destination owes less than requested", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 17_000)
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [transfer_deposit_operation("group-81", "group-b", 17_000)])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_outstanding"}] =
               results(conn)

      assert %{"cash_held_cents" => 17_000} = ledger_data(conn)

      assert %{"outstanding_deposit_cents" => 16_000} =
               Map.take(group_data(conn, "group-b"), ["outstanding_deposit_cents"])
    end

    test "operations missing identifying data are invalid_operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          transfer_deposit_operation(nil, "group-b", 100, %{"operation_id" => "op-no-src"}),
          transfer_deposit_operation("group-81", "", 100, %{"operation_id" => "op-blank-dst"}),
          transfer_deposit_operation("group-81", "group-b", 100, %{
            "operation_id" => "op-no-date",
            "occurred_on" => nil
          })
        ])

      for result <- results(conn) do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end
    end
  end

  describe "durability and batch behavior" do
    test "a retry returns the exact stored result without moving funding again", %{conn: conn} do
      operation = transfer_deposit_operation("group-81", "group-b", 3_000)

      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 5_000),
          operation
        ])

      assert [_open, _dest, _pay, applied] = results(conn)
      assert %{"status" => "applied", "source_revision" => 3} = applied

      retry = post_operations(conn, [operation]) |> results() |> hd()
      assert retry == applied

      # The replay moved nothing further.
      assert %{"revision" => 3} = Map.take(group_data(conn, "group-81"), ["revision"])

      assert %{"revision" => 2, "cash_paid_cents" => 3_000} =
               Map.take(group_data(conn, "group-b"), ["revision", "cash_paid_cents"])

      assert %{"cash_held_cents" => 5_000} = ledger_data(conn)

      variant =
        post_operations(conn, [
          transfer_deposit_operation("group-81", "group-b", 2_999, %{
            "operation_id" => operation["operation_id"]
          })
        ])
        |> results()
        |> hd()

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = variant
    end

    test "same-batch operations observe earlier results", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_destination(),
          payment_operation("group-81", 5_000),
          transfer_deposit_operation("group-81", "group-b", 2_000),
          # The source's reopened outstanding reflects the transfer that ran
          # just before it in the same batch.
          payment_operation("group-81", 16_500)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "source_outstanding_deposit_cents" => 16_500},
               %{"status" => "applied", "outstanding_deposit_cents" => 0}
             ] = results(conn)

      assert %{"cash_held_cents" => 21_500} = ledger_data(conn)
    end
  end
end
