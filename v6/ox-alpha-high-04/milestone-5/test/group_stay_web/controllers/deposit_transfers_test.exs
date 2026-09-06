defmodule GroupStayWeb.DepositTransfersTest do
  @moduledoc """
  The transfer_deposit operation delivered with this release: moving held
  funding between two active groups of the same guest, the revision
  contract across groups, the statement's `held_by_group` evolution, and
  the way reductions and chargebacks follow a payment's allocations
  wherever they currently fund rooms.
  """

  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  # group-81 defaults: flexible, booked 2026-10-03, arrival 2026-12-10 with
  # rooms room-a (15000/night) and room-b (17500/night) for 3 nights, so
  # room-a is due 9000 and room-b is due 10500 (group due 19500); the stay
  # is refundable through 2026-11-26.
  @refundable "2026-11-01"

  # group-92: same guest, flexible, arrival 2026-12-20 with rooms room-c
  # (20000/night) and room-d (10000/night) for 3 nights, so room-c is due
  # 12000 and room-d is due 6000 (group due 18000); refundable through
  # 2026-12-06.
  defp open_second_group(overrides \\ %{}) do
    open_group(%{
      "operation_id" => "open-92",
      "group_id" => "group-92",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-23",
      "rooms" => [
        %{"room_id" => "room-c", "nightly_rate_cents" => 20000},
        %{"room_id" => "room-d", "nightly_rate_cents" => 10000}
      ]
    })
    |> Map.merge(overrides)
  end

  defp open_advance_group(overrides \\ %{}) do
    open_group(%{
      "operation_id" => "open-93",
      "group_id" => "group-93",
      "rate_plan" => "advance_purchase",
      "arrival_on" => "2027-01-10",
      "departure_on" => "2027-01-13",
      "rooms" => [%{"room_id" => "room-e", "nightly_rate_cents" => 15000}]
    })
    |> Map.merge(overrides)
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", batch(List.wrap(operations)))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_data(conn, path) do
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp room_view(group_data, room_id) do
    Enum.find(group_data["rooms"], &(&1["room_id"] == room_id))
  end

  ## Moving held funding

  describe "transfer_deposit" do
    test "moves held cash in reverse allocation order and fills the destination in room order", %{
      conn: conn
    } do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"})
      ])

      results = submit(conn, transfer_deposit("group-81", "group-92", 4000))

      assert [
               %{
                 "status" => "applied",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-92",
                 "amount_cents" => 4000,
                 "source_outstanding_deposit_cents" => 13_500,
                 "destination_outstanding_deposit_cents" => 14_000,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = results

      # Reverse allocation order on the source: room-b's 1000 leave first,
      # then 3000 of room-a's. The destination fills room-c first.
      source = get_data(conn, "/api/v1/groups/group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 6000
      assert room_view(source, "room-b")["cash_paid_cents"] == 0
      assert source["cash_paid_cents"] == 6000

      destination = get_data(conn, "/api/v1/groups/group-92")
      assert room_view(destination, "room-c")["cash_paid_cents"] == 4000
      assert room_view(destination, "room-d")["cash_paid_cents"] == 0
      assert destination["cash_paid_cents"] == 4000

      # A transfer settles and revalues nothing: the ledger total is where
      # it was, only its attribution moved.
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 10_000
    end

    test "moves a partially drawn allocation, leaving its remainder in place", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"})
      ])

      assert [%{"source_outstanding_deposit_cents" => 19_000}] =
               submit(conn, transfer_deposit("group-81", "group-92", 9500))

      source = get_data(conn, "/api/v1/groups/group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 500
      assert room_view(source, "room-b")["cash_paid_cents"] == 0

      destination = get_data(conn, "/api/v1/groups/group-92")
      assert room_view(destination, "room-c")["cash_paid_cents"] == 9500

      assert get_data(conn, "/api/v1/payments/pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 500},
               %{"group_id" => "group-92", "amount_cents" => 9500}
             ]
    end

    test "sees earlier operations of the same batch", %{conn: conn} do
      results =
        submit(conn, [
          open_group(),
          open_second_group(),
          pay("group-81", 10000, %{"operation_id" => "pay-1"}),
          transfer_deposit("group-81", "group-92", 4000)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "applied",
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = results
    end

    test "moves cash and credit alike, keeping each piece's provenance", %{conn: conn} do
      # A seed cancellation issues the lot the later application consumes.
      submit(conn, [
        open_group(%{"operation_id" => "open-seed", "group_id" => "group-seed"}),
        pay("group-seed", 10000, %{"operation_id" => "pay-seed"}),
        cancel("group-seed", @refundable, %{
          "operation_id" => "cancel-seed",
          "refund_method" => "hotel_credit"
        })
      ])

      # room-a ends up fully funded: 3000 of lot credit drawn first, then
      # 6000 of pay-1 cash.
      submit(conn, [
        open_group(),
        open_second_group(),
        apply_hotel_credit("group-81", 3000, %{"operation_id" => "apply-lot"}),
        pay("group-81", 6000, %{"operation_id" => "pay-1"})
      ])

      assert [%{"status" => "applied"}] =
               submit(conn, transfer_deposit("group-81", "group-92", 8000))

      # Reverse allocation order ignores the funding kind: the most recently
      # created cash allocation leaves first, then part of the credit. Each
      # moved piece keeps its provenance on the destination's room-c.
      destination = get_data(conn, "/api/v1/groups/group-92")
      assert room_view(destination, "room-c")["cash_paid_cents"] == 6000
      assert room_view(destination, "room-c")["credit_paid_cents"] == 2000

      source = get_data(conn, "/api/v1/groups/group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 0
      assert room_view(source, "room-a")["credit_paid_cents"] == 1000

      # A refundable settlement at the destination refunds the transferred
      # cash and restores the transferred credit to its original lot with
      # its original expiry — without a second bonus.
      results = submit(conn, cancel("group-92", "2026-11-15"))

      assert [%{"status" => "applied", "refunded_cents" => 6000, "credit_issued_cents" => 0}] =
               results

      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 10_000,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-seed",
                   "remaining_cents" => 10_000,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }

      # The 1000 still applied at the source keeps its expiry paused inside
      # the liability.
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 11_000
      assert get_data(conn, "/api/v1/ledger")["cash_refunded_cents"] == 6000
    end

    test "a non-refundable settlement consumes transferred credit normally", %{conn: conn} do
      submit(conn, [
        open_group(%{"operation_id" => "open-seed", "group_id" => "group-seed"}),
        pay("group-seed", 10000, %{"operation_id" => "pay-seed"}),
        cancel("group-seed", @refundable, %{
          "operation_id" => "cancel-seed",
          "refund_method" => "hotel_credit"
        }),
        open_second_group(),
        open_advance_group(),
        apply_hotel_credit("group-92", 11000, %{"operation_id" => "apply-lot"}),
        transfer_deposit("group-92", "group-93", 6000, %{"operation_id" => "t-credit"})
      ])

      # group-93 is advance purchase: the credit that arrived there is
      # consumed by its non-refundable settlement; the rest stays applied
      # with its expiry paused at the source.
      assert [%{"status" => "applied", "retained_cents" => 0}] =
               submit(conn, cancel("group-93", "2027-01-01", %{"operation_id" => "cancel-adv"}))

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 5000
      assert get_data(conn, "/api/v1/groups/group-92")["credit_paid_cents"] == 5000
    end

    test "transferred cash settles under the destination group's policy", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_advance_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-93", 4000)
      ])

      # The destination is advance purchase: always non-refundable, whatever
      # the source's policy would have done with this cash.
      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 4000}] =
               submit(conn, cancel("group-93", "2027-01-01"))

      assert [%{"status" => "applied", "refunded_cents" => 6000}] =
               submit(conn, cancel("group-81", @refundable))

      assert get_data(conn, "/api/v1/ledger")["cash_retained_cents"] == 4000
      assert get_data(conn, "/api/v1/ledger")["cash_refunded_cents"] == 6000
    end

    test "transferred cash converted at the destination earns the bonus there", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 4000)
      ])

      assert [%{"status" => "applied", "credit_issued_cents" => 4400, "refunded_cents" => 0}] =
               submit(
                 conn,
                 cancel("group-92", "2026-11-15", %{"refund_method" => "hotel_credit"})
               )

      assert [%{"status" => "applied", "refunded_cents" => 6000}] =
               submit(conn, cancel("group-81", @refundable))

      assert get_data(conn, "/api/v1/ledger")["cash_converted_to_credit_cents"] == 4000
    end

    test "is durably idempotent", %{conn: conn} do
      submit(conn, [open_group(), open_second_group(), pay("group-81", 10000)])

      op = transfer_deposit("group-81", "group-92", 4000, %{"operation_id" => "transfer-once"})

      [first] = submit(conn, [op])

      assert submit(conn, [op]) == [first]

      data = get_data(conn, "/api/v1/groups/group-81")
      assert data["revision"] == 3
      assert room_view(data, "room-a")["cash_paid_cents"] == 6000
    end
  end

  describe "transfer_deposit rejections" do
    test "rejects the same group or different guests with invalid_transfer", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_group(%{
          "operation_id" => "open-other",
          "group_id" => "group-other",
          "guest_id" => "guest-77"
        })
      ])

      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               submit(conn, transfer_deposit("group-81", "group-81", 100))

      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               submit(conn, transfer_deposit("group-81", "group-other", 100))
    end

    test "rejects an inactive group with that group's group_id", %{conn: conn} do
      submit(conn, [open_group(), open_second_group()])

      submit(conn, cancel("group-92", "2026-11-15", %{"operation_id" => "cancel-92"}))

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "group-92"
               }
             ] = submit(conn, transfer_deposit("group-81", "group-92", 100))

      submit(conn, cancel("group-81", @refundable, %{"operation_id" => "cancel-81"}))

      assert [%{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"}] =
               submit(
                 conn,
                 transfer_deposit("group-81", "group-92", 100, %{"operation_id" => "t-again"})
               )
    end

    test "rejects a non-positive amount with invalid_amount", %{conn: conn} do
      submit(conn, [open_group(), open_second_group(), pay("group-81", 10000)])

      for bad <- [0, -500] do
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(conn, transfer_deposit("group-81", "group-92", bad))
      end
    end

    test "rejects when the source holds less than requested", %{conn: conn} do
      submit(conn, [open_group(), open_second_group()])

      # Nothing is held at all yet.
      assert [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}] =
               submit(conn, transfer_deposit("group-81", "group-92", 100))

      submit(conn, [pay("group-81", 5000, %{"operation_id" => "pay-1"})])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}] =
               submit(conn, transfer_deposit("group-81", "group-92", 5001))
    end

    test "rejects when the destination has less outstanding than requested", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 19500, %{"operation_id" => "pay-1"})
      ])

      # 19000 is fully held by the source but exceeds the destination's
      # 18000 outstanding deposit.
      assert [%{"status" => "rejected", "code" => "transfer_exceeds_outstanding"}] =
               submit(conn, transfer_deposit("group-81", "group-92", 19_000))

      # Nothing moved.
      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 2
      assert get_data(conn, "/api/v1/groups/group-92")["revision"] == 1
    end

    test "resolves source existence before destination existence", %{conn: conn} do
      submit(conn, [open_group()])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "group-ghost"
               }
             ] = submit(conn, transfer_deposit("group-ghost", "group-92", 100))

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "group-ghost"
               }
             ] = submit(conn, transfer_deposit("group-81", "group-ghost", 100))
    end

    test "accepts matching guards for both groups and moves the funding", %{conn: conn} do
      submit(conn, [open_group(), open_second_group(), pay("group-81", 10000)])

      results =
        submit(
          conn,
          transfer_deposit("group-81", "group-92", 4000, %{
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        )

      assert [%{"status" => "applied", "source_revision" => 3, "destination_revision" => 2}] =
               results

      assert room_view(get_data(conn, "/api/v1/groups/group-92"), "room-c")["cash_paid_cents"] ==
               4000
    end

    test "checks the source revision, then the destination revision", %{conn: conn} do
      submit(conn, [open_group(), open_second_group(), pay("group-81", 10000)])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] =
               submit(
                 conn,
                 transfer_deposit("group-81", "group-92", 100, %{"expected_revision" => 1})
               )

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-92",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
             ] =
               submit(
                 conn,
                 transfer_deposit("group-81", "group-92", 100, %{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 9
                 })
               )
    end

    test "checks revisions before the transfer rules", %{conn: conn} do
      submit(conn, [open_group(), open_second_group(), pay("group-81", 10000)])

      # A stale source revision wins over a non-positive amount.
      assert [%{"status" => "rejected", "code" => "stale_revision", "group_id" => "group-81"}] =
               submit(
                 conn,
                 transfer_deposit("group-81", "group-92", 0, %{"expected_revision" => 1})
               )

      # It also wins over the same-group rule.
      assert [%{"status" => "rejected", "code" => "stale_revision", "group_id" => "group-81"}] =
               submit(
                 conn,
                 transfer_deposit("group-81", "group-81", 100, %{"expected_revision" => 1})
               )
    end

    test "applies the transfer rules in their documented order", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_group(%{
          "operation_id" => "open-other",
          "group_id" => "group-other",
          "guest_id" => "guest-77"
        })
      ])

      # A rejected transfer never moves state or revisions.
      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 1

      submit(conn, cancel("group-81", @refundable))

      # The guest rule precedes the activity rule.
      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               submit(conn, transfer_deposit("group-81", "group-other", 100))
    end
  end

  ## Payment statement evolution

  describe "payment statement held_by_group" do
    test "payments that never participated in a transfer keep the earlier shape", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      data = get_data(conn, "/api/v1/payments/pay-1")

      assert Map.keys(data) |> Enum.sort() == [
               "charged_back_cents",
               "converted_to_credit_cents",
               "held_cents",
               "payment_operation_id",
               "recorded_cents",
               "reduced_cents",
               "refunded_cents",
               "retained_cents"
             ]
    end

    test "once transferred, held cash is listed per group and sums to held_cents", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 4000)
      ])

      data = get_data(conn, "/api/v1/payments/pay-1")

      assert data["held_cents"] == 10_000

      assert data["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 6000},
               %{"group_id" => "group-92", "amount_cents" => 4000}
             ]

      assert Enum.sum(Enum.map(data["held_by_group"], & &1["amount_cents"])) ==
               data["held_cents"]
    end

    test "omits groups with no held cash and empties once nothing remains", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 10000)
      ])

      data = get_data(conn, "/api/v1/payments/pay-1")

      assert data["held_by_group"] == [%{"group_id" => "group-92", "amount_cents" => 10_000}]

      submit(conn, reduce_cash("pay-1", 10000, %{"operation_id" => "reduce-1"}))

      assert get_data(conn, "/api/v1/payments/pay-1")["held_by_group"] == []
      assert get_data(conn, "/api/v1/payments/pay-1")["held_cents"] == 0
    end
  end

  ## Reductions and chargebacks across groups

  describe "reductions and chargebacks across groups" do
    test "a reduction follows the payment's allocations across groups", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 4000)
      ])

      results = submit(conn, reduce_cash("pay-1", 10000))

      assert [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 4
               }
             ] = results

      # Reverse allocation order across all groups: the transferred 4000
      # leave group-92 first, then group-81's remaining 6000.
      assert room_view(get_data(conn, "/api/v1/groups/group-92"), "room-c")["cash_paid_cents"] ==
               0

      assert get_data(conn, "/api/v1/groups/group-92")["revision"] == 3
      assert get_data(conn, "/api/v1/ledger")["cash_reduced_cents"] == 10_000
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 0
    end

    test "a partial reduction bumps the unaddressed group's revision too", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 4000)
      ])

      results = submit(conn, reduce_cash("pay-1", 5000))

      assert [%{"status" => "applied", "revision" => 4, "outstanding_deposit_cents" => 14_500}] =
               results

      # The transfer moved room-b's 1000 and 3000 of room-a's: the reduction
      # takes group-92's 4000 first, then 1000 of group-81's room-a.
      assert room_view(get_data(conn, "/api/v1/groups/group-81"), "room-a")["cash_paid_cents"] ==
               5000

      assert get_data(conn, "/api/v1/groups/group-92")["revision"] == 3

      assert room_view(get_data(conn, "/api/v1/groups/group-92"), "room-c")["cash_paid_cents"] ==
               0
    end

    test "a reduction of fully transferred cash still bumps the addressed group", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 10000)
      ])

      results = submit(conn, reduce_cash("pay-1", 10000))

      assert [%{"status" => "applied", "group_id" => "group-81", "revision" => 4}] = results

      # Nothing was held at the addressed group, but it was addressed, so
      # its revision advanced with the others.
      assert get_data(conn, "/api/v1/groups/group-81")["cash_paid_cents"] == 0
      assert get_data(conn, "/api/v1/groups/group-92")["revision"] == 3
      assert get_data(conn, "/api/v1/groups/group-92")["cash_paid_cents"] == 0
    end

    test "a chargeback follows the payment's allocations across groups", %{conn: conn} do
      submit(conn, [
        open_group(),
        open_second_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        transfer_deposit("group-81", "group-92", 4000)
      ])

      results = submit(conn, charge_back("pay-1"))

      assert [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-81",
                 "charged_back_cents" => 10_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 4
               }
             ] = results

      assert get_data(conn, "/api/v1/groups/group-92")["revision"] == 3

      assert room_view(get_data(conn, "/api/v1/groups/group-92"), "room-c")["cash_paid_cents"] ==
               0

      assert get_data(conn, "/api/v1/ledger")["cash_charged_back_cents"] == 10_000
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 0
    end
  end
end
