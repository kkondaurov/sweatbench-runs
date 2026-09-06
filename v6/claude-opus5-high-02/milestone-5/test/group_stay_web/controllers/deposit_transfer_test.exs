defmodule GroupStayWeb.DepositTransferTest do
  @moduledoc """
  Moving applied deposit between two active reservations of one guest.

  A transfer is not a settlement: no money moves through a provider, no bonus is computed, and no
  finance total changes. All that changes is which active rooms hold the funding, and which
  revisions the two groups are on.
  """

  use GroupStayWeb.ConnCase, async: false

  # One night in each group. Group 81 holds a 4_000 deposit over two rooms, group 92 holds 4_000
  # over one, so a transfer between them has room at both ends.
  defp source(overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "operation_id" => "op-open-81",
          "group_id" => "group-81",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room("room-a", 10_000), room("room-b", 10_000)]
        },
        overrides
      )
    )
  end

  defp destination(overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room("room-c", 10_000), room("room-d", 10_000)]
        },
        overrides
      )
    )
  end

  defp funded_pair(payment \\ %{}) do
    [
      source(),
      destination(),
      record_cash_payment(Map.merge(%{"amount_cents" => 3_000}, payment))
    ]
  end

  describe "moving held funding" do
    test "moves cash from the source's rooms to the destination's" do
      results = submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_500})])
      result = List.last(results)

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 1_500,
               "source_outstanding_deposit_cents" => 2_500,
               "destination_outstanding_deposit_cents" => 2_500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      # The source gives up its most recently filled room first; the destination fills its rooms
      # in their original order.
      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 1_500},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = read_rooms("group-81")

      assert [
               %{"room_id" => "room-c", "cash_paid_cents" => 1_500},
               %{"room_id" => "room-d", "cash_paid_cents" => 0}
             ] = read_rooms("group-92")
    end

    test "draws the most recently created allocation first, whatever kind of funding it is" do
      issue_credit(group_id: "group-credit", cash_cents: 1_000, operation_id: "cancel-17")

      submit([
        source(),
        destination(),
        record_cash_payment(%{"amount_cents" => 2_000}),
        apply_hotel_credit(%{"amount_cents" => 1_000}),
        transfer_deposit(%{"amount_cents" => 1_500})
      ])

      # The credit was applied last, so all 1_000 of it leaves before any cash does.
      assert %{"cash_paid_cents" => 1_500, "credit_paid_cents" => 0} =
               group_totals("group-81")

      assert %{"cash_paid_cents" => 500, "credit_paid_cents" => 1_000} =
               group_totals("group-92")
    end

    test "preserves the order units were drawn in while filling the destination's rooms" do
      issue_credit(group_id: "group-credit", cash_cents: 1_000, operation_id: "cancel-17")

      submit([
        source(),
        # The destination's first room only takes 1_000, so the first unit drawn fills it and the
        # second goes on to the next room.
        destination(%{"rooms" => [room("room-c", 5_000), room("room-d", 10_000)]}),
        record_cash_payment(%{"amount_cents" => 2_000}),
        apply_hotel_credit(%{"amount_cents" => 1_000}),
        transfer_deposit(%{"amount_cents" => 2_000})
      ])

      # Credit was drawn first because it was applied last, so it is what fills room-c.
      assert [
               %{"room_id" => "room-c", "cash_paid_cents" => 0, "credit_paid_cents" => 1_000},
               %{"room_id" => "room-d", "cash_paid_cents" => 1_000, "credit_paid_cents" => 0}
             ] = read_rooms("group-92")
    end

    test "moves the whole of the source's held funding when asked for all of it" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 3_000})])

      assert %{"deposit_paid_cents" => 0, "outstanding_deposit_cents" => 4_000} =
               group_totals("group-81")

      assert %{"deposit_paid_cents" => 3_000, "outstanding_deposit_cents" => 1_000} =
               group_totals("group-92")
    end

    test "leaves every finance total alone" do
      submit(funded_pair())
      before = read_ledger()

      submit([transfer_deposit(%{"amount_cents" => 1_500})])

      assert read_ledger() == before
      assert before["cash_held_cents"] == 3_000
    end

    test "leaves applied credit applied, with its expiry still paused" do
      issue_credit(group_id: "group-credit", cash_cents: 1_000, operation_id: "cancel-17")

      submit([
        source(),
        destination(),
        apply_hotel_credit(%{"amount_cents" => 1_100}),
        transfer_deposit(%{"amount_cents" => 1_100})
      ])

      # Credit funding a group is a liability but is not available to spend, wherever it sits.
      assert read_ledger()["credit_liability_cents"] == 1_100
      assert read_credit("guest-22")["available_cents"] == 0

      # Cancelling the destination while refundable returns it to its original lot and expiry.
      submit([
        cancel_group(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-01"
        })
      ])

      assert %{"available_cents" => 1_100, "lots" => [lot]} = read_credit("guest-22")
      assert lot["source_operation_id"] == "cancel-17"
      assert lot["remaining_cents"] == 1_100
      assert lot["expires_on"] == "2027-11-26"
    end
  end

  describe "settling transferred funding" do
    test "transferred cash settles under the destination's policy" do
      submit([
        source(),
        # Booked in 2027, so the destination carries the 30-day window its own booking implies.
        destination(%{
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-11"
        }),
        record_cash_payment(%{"amount_cents" => 2_000}),
        transfer_deposit(%{"amount_cents" => 2_000})
      ])

      # 30 days before arrival is 2027-11-10, so a cancellation on the 20th is not refundable,
      # even though the source group it came from would still have been.
      refused =
        submit_one(
          cancel_group(%{
            "operation_id" => "op-credit-92",
            "group_id" => "group-92",
            "occurred_on" => "2027-11-20",
            "refund_method" => "hotel_credit"
          })
        )

      assert refused["code"] == "refund_method_not_available"

      submit([
        cancel_group(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2027-11-20"
        })
      ])

      assert read_ledger()["cash_retained_cents"] == 2_000
      assert read_ledger()["cash_refunded_cents"] == 0
    end

    test "converting transferred cash earns the bonus on the cash settled there" do
      submit([
        source(),
        destination(),
        record_cash_payment(%{"amount_cents" => 2_000}),
        transfer_deposit(%{"amount_cents" => 1_500}),
        cancel_group(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      ])

      assert %{"available_cents" => 1_650, "lots" => [%{"remaining_cents" => 1_650}]} =
               read_credit("guest-22")

      assert read_ledger()["cash_converted_to_credit_cents"] == 1_500
    end

    test "transferred departure of a group only settles what that group still holds" do
      results =
        submit(
          funded_pair() ++
            [
              transfer_deposit(%{"amount_cents" => 1_000}),
              cancel_group(%{"operation_id" => "op-cancel-81", "group_id" => "group-81"})
            ]
        )

      assert %{"refunded_cents" => 2_000} = List.last(results)
      assert read_ledger()["cash_held_cents"] == 1_000
    end
  end

  describe "settling rooms around a transfer" do
    test "only funding on active rooms can be transferred" do
      submit(
        funded_pair() ++
          [
            # 2_000 of the payment funded room-a, which is settled and takes that cash with it.
            cancel_rooms(%{"group_id" => "group-81", "room_ids" => ["room-a"]})
          ]
      )

      assert submit_one(transfer_deposit(%{"amount_cents" => 1_001}))["code"] ==
               "transfer_exceeds_held_funding"

      result = submit_one(transfer_deposit(%{"operation_id" => "op-t2", "amount_cents" => 1_000}))

      assert result["status"] == "applied"
      assert %{"deposit_paid_cents" => 0} = group_totals("group-81")
      assert %{"deposit_paid_cents" => 1_000} = group_totals("group-92")
    end

    test "transferred credit consumed by a non-refundable settlement leaves the liability" do
      issue_credit(group_id: "group-credit", cash_cents: 1_000, operation_id: "cancel-17")

      submit([
        source(),
        destination(),
        apply_hotel_credit(%{"amount_cents" => 1_100}),
        transfer_deposit(%{"amount_cents" => 1_100}),
        # Arrival is 2026-12-10 and the window is 14 days, so this is past the refundable date.
        cancel_group(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-12-01"
        })
      ])

      assert read_ledger()["credit_liability_cents"] == 0
      assert read_credit("guest-22")["available_cents"] == 0
    end
  end

  describe "corrections that follow transferred cash" do
    test "a reduction unwinds a payment's allocations in reverse order across both groups" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_000})])

      # 2_000 is still held in group-81 and 1_000 in group-92; the transferred part was drawn
      # last, so it is the first to go.
      result = submit_one(reduce_cash_payment(%{"amount_cents" => 1_500}))

      assert result["status"] == "applied"
      assert result["group_id"] == "group-81"
      assert %{"deposit_paid_cents" => 1_500} = group_totals("group-81")
      assert %{"deposit_paid_cents" => 0} = group_totals("group-92")
      assert read_ledger()["cash_reduced_cents"] == 1_500
    end

    test "a correction moves the revision of every group whose funding it changes" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_000})])

      assert group_totals("group-81")["revision"] == 3
      assert group_totals("group-92")["revision"] == 2

      result = submit_one(reduce_cash_payment(%{"amount_cents" => 1_500}))

      # The reduction addresses the payment's own group, and reports that group's revision.
      assert result["revision"] == 4
      assert group_totals("group-81")["revision"] == 4
      assert group_totals("group-92")["revision"] == 3
    end

    test "a reduction still addresses the payment's own group when only another group holds it" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 3_000})])

      result = submit_one(reduce_cash_payment(%{"amount_cents" => 500}))

      assert result["group_id"] == "group-81"
      assert result["outstanding_deposit_cents"] == 4_000

      # The addressed group moves on a revision even though the cash left group-92, and group-92
      # moves on one because its funding changed.
      assert group_totals("group-81")["revision"] == 4
      assert group_totals("group-92")["revision"] == 3
      assert %{"deposit_paid_cents" => 2_500} = group_totals("group-92")
    end

    test "a partly reduced allocation keeps the rest funding the group it was moved to" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_000})])

      submit_one(reduce_cash_payment(%{"amount_cents" => 400}))

      {200, %{"data" => statement}} = read_payment("op-pay")

      assert statement["reduced_cents"] == 400
      assert statement["held_cents"] == 2_600

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 2_000},
               %{"group_id" => "group-92", "amount_cents" => 600}
             ]
    end

    test "a chargeback reverses the payment wherever its cash now sits" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_000})])

      result = submit_one(charge_back_payment())

      assert result["charged_back_cents"] == 3_000
      assert result["group_id"] == "group-81"
      assert %{"deposit_paid_cents" => 0} = group_totals("group-81")
      assert %{"deposit_paid_cents" => 0} = group_totals("group-92")
      assert read_ledger()["cash_charged_back_cents"] == 3_000
      assert read_ledger()["cash_held_cents"] == 0
    end

    test "a chargeback leaves groups it did not take held cash from where they were" do
      submit(
        funded_pair() ++
          [
            transfer_deposit(%{"amount_cents" => 1_000}),
            cancel_group(%{
              "operation_id" => "op-cancel-92",
              "group_id" => "group-92",
              "occurred_on" => "2026-11-01"
            })
          ]
      )

      revision = group_totals("group-92")["revision"]

      submit_one(charge_back_payment())

      # The cash that had been transferred was refunded long before, so group-92 holds nothing
      # the chargeback can take back out of it.
      assert group_totals("group-92")["revision"] == revision
      assert read_ledger()["cash_charged_back_cents"] == 3_000
      assert read_ledger()["cash_refunded_cents"] == 0
    end
  end

  describe "credit issued from transferred cash" do
    test "a chargeback takes back what the payment bought in every lot it reached" do
      submit(
        funded_pair() ++
          [
            transfer_deposit(%{"amount_cents" => 1_000}),
            cancel_group(%{
              "operation_id" => "cancel-92",
              "group_id" => "group-92",
              "occurred_on" => "2026-11-01",
              "refund_method" => "hotel_credit"
            }),
            cancel_group(%{
              "operation_id" => "cancel-81",
              "group_id" => "group-81",
              "occurred_on" => "2026-11-01",
              "refund_method" => "hotel_credit"
            })
          ]
      )

      # One lot per settlement, each worth its own cash plus the standard bonus.
      assert %{"available_cents" => 3_300} = read_credit("guest-22")

      result = submit_one(charge_back_payment())

      assert result["charged_back_cents"] == 3_000
      assert read_credit("guest-22")["available_cents"] == 0
      assert read_ledger()["credit_liability_cents"] == 0
      assert read_ledger()["credit_shortfall_cents"] == 0
      assert read_ledger()["cash_converted_to_credit_cents"] == 0
      assert read_ledger()["cash_charged_back_cents"] == 3_000
    end

    test "credit already spent elsewhere leaves the lot short without touching that group" do
      submit(
        funded_pair() ++
          [
            transfer_deposit(%{"amount_cents" => 1_000}),
            cancel_group(%{
              "operation_id" => "cancel-92",
              "group_id" => "group-92",
              "occurred_on" => "2026-11-01",
              "refund_method" => "hotel_credit"
            }),
            source(%{"operation_id" => "op-open-93", "group_id" => "group-93"}),
            apply_hotel_credit(%{"group_id" => "group-93", "amount_cents" => 1_100})
          ]
      )

      revision = group_totals("group-93")["revision"]

      submit_one(charge_back_payment())

      # The lot cannot give back credit that is already funding group-93, so it stays short, and
      # group-93 itself is left exactly where it was.
      assert read_ledger()["credit_shortfall_cents"] == 1_100
      assert read_ledger()["credit_liability_cents"] == 1_100
      assert group_totals("group-93")["revision"] == revision
      assert %{"deposit_paid_cents" => 1_100} = group_totals("group-93")
    end
  end

  describe "the payment statement" do
    test "says which groups hold a transferred payment's cash" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_000})])

      assert {200, %{"data" => statement}} = read_payment("op-pay")

      assert statement["held_cents"] == 3_000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 2_000},
               %{"group_id" => "group-92", "amount_cents" => 1_000}
             ]
    end

    test "omits groups holding none of it and empties once none is held" do
      submit(
        funded_pair() ++
          [
            transfer_deposit(%{"amount_cents" => 1_000}),
            cancel_group(%{"operation_id" => "op-cancel-81", "group_id" => "group-81"})
          ]
      )

      {200, %{"data" => statement}} = read_payment("op-pay")

      assert statement["held_by_group"] == [%{"group_id" => "group-92", "amount_cents" => 1_000}]

      submit([
        cancel_group(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-01"
        })
      ])

      {200, %{"data" => statement}} = read_payment("op-pay")

      assert statement["held_by_group"] == []
      assert statement["refunded_cents"] == 3_000
      assert statement["recorded_cents"] == 3_000
    end

    test "a payment that never took part in a transfer keeps the earlier shape" do
      submit(funded_pair() ++ [transfer_deposit(%{"amount_cents" => 1_000})])

      submit([
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-92",
          "amount_cents" => 500
        })
      ])

      {200, %{"data" => statement}} = read_payment("op-pay-2")

      refute Map.has_key?(statement, "held_by_group")

      assert Enum.sort(Map.keys(statement)) == [
               "charged_back_cents",
               "converted_to_credit_cents",
               "held_cents",
               "original_group_id",
               "payment_operation_id",
               "recorded_cents",
               "reduced_cents",
               "refunded_cents",
               "retained_cents"
             ]
    end
  end

  describe "rejections" do
    test "resolves the source group before the destination" do
      submit([destination()])

      result =
        submit_one(
          transfer_deposit(%{
            "source_group_id" => "group-404",
            "destination_group_id" => "group-405"
          })
        )

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-404"
             }
    end

    test "names the destination when only the destination is missing" do
      submit([source()])

      result = submit_one(transfer_deposit())

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-92"
    end

    test "checks the source revision before the destination revision" do
      submit(funded_pair())

      result =
        submit_one(
          transfer_deposit(%{
            "expected_revision" => 1,
            "destination_expected_revision" => 9
          })
        )

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "reports a stale destination revision against the destination" do
      submit(funded_pair())

      result =
        submit_one(
          transfer_deposit(%{
            "expected_revision" => 2,
            "destination_expected_revision" => 9
          })
        )

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
    end

    test "applies a transfer that matches both revisions" do
      submit(funded_pair())

      result =
        submit_one(
          transfer_deposit(%{
            "amount_cents" => 1_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        )

      assert result["status"] == "applied"
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2
    end

    test "rejects a transfer to the same group or to another guest's group" do
      submit(
        funded_pair() ++
          [
            destination(%{
              "operation_id" => "op-open-93",
              "group_id" => "group-93",
              "guest_id" => "guest-99"
            })
          ]
      )

      assert submit_one(transfer_deposit(%{"destination_group_id" => "group-81"}))["code"] ==
               "invalid_transfer"

      assert submit_one(
               transfer_deposit(%{
                 "operation_id" => "op-transfer-2",
                 "destination_group_id" => "group-93"
               })
             )["code"] == "invalid_transfer"
    end

    test "names the group that is no longer active" do
      submit(
        funded_pair() ++
          [
            cancel_group(%{
              "operation_id" => "op-cancel-92",
              "group_id" => "group-92",
              "occurred_on" => "2026-11-01"
            })
          ]
      )

      result = submit_one(transfer_deposit())

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-92"

      submit([cancel_group(%{"operation_id" => "op-cancel-81", "group_id" => "group-81"})])

      result = submit_one(transfer_deposit(%{"operation_id" => "op-transfer-2"}))

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-81"
    end

    test "rejects an amount that is not a transfer" do
      submit(funded_pair())

      for {amount, index} <- Enum.with_index([0, -100, "1000"]) do
        result =
          submit_one(
            transfer_deposit(%{
              "operation_id" => "op-transfer-#{index}",
              "amount_cents" => amount
            })
          )

        assert result["code"] == "invalid_amount"
      end
    end

    test "rejects more than the source holds" do
      submit(funded_pair())

      result = submit_one(transfer_deposit(%{"amount_cents" => 3_001}))

      assert result["code"] == "transfer_exceeds_held_funding"
      assert %{"deposit_paid_cents" => 3_000, "revision" => 2} = group_totals("group-81")
    end

    test "rejects more than the destination still owes" do
      submit([
        source(),
        destination(%{"rooms" => [room("room-c", 5_000)]}),
        record_cash_payment(%{"amount_cents" => 3_000})
      ])

      result = submit_one(transfer_deposit(%{"amount_cents" => 1_001}))

      assert result["code"] == "transfer_exceeds_outstanding"
      assert %{"deposit_paid_cents" => 3_000} = group_totals("group-81")
      assert %{"revision" => 1} = group_totals("group-92")
    end

    test "a rejected transfer moves nothing and no revision" do
      submit(funded_pair())

      submit_one(transfer_deposit(%{"amount_cents" => 9_999}))

      assert %{"deposit_paid_cents" => 3_000, "revision" => 2} = group_totals("group-81")
      assert %{"deposit_paid_cents" => 0, "revision" => 1} = group_totals("group-92")
      assert read_ledger()["cash_held_cents"] == 3_000
    end

    test "rejects a transfer that cannot be identified" do
      submit(funded_pair())

      missing_destination = Map.delete(transfer_deposit(), "destination_group_id")

      missing_source =
        Map.delete(transfer_deposit(%{"operation_id" => "op-a"}), "source_group_id")

      bad_revision =
        transfer_deposit(%{"operation_id" => "op-b", "destination_expected_revision" => 0})

      for operation <- [missing_destination, missing_source, bad_revision] do
        assert submit_one(operation)["code"] == "invalid_operation"
      end
    end
  end

  describe "durability" do
    test "a retry returns the stored result without moving funding again" do
      submit(funded_pair())

      first = submit_one(transfer_deposit(%{"amount_cents" => 1_000}))
      retry = submit_one(transfer_deposit(%{"amount_cents" => 1_000}))

      assert retry == first
      assert %{"deposit_paid_cents" => 2_000, "revision" => 3} = group_totals("group-81")
      assert %{"deposit_paid_cents" => 1_000, "revision" => 2} = group_totals("group-92")
      assert read_operation("op-transfer") == {200, %{"data" => first}}
    end

    test "reusing the identifier for a different transfer is a conflict" do
      submit(funded_pair())

      submit_one(transfer_deposit(%{"amount_cents" => 1_000}))
      retry = submit_one(transfer_deposit(%{"amount_cents" => 500}))

      assert retry["code"] == "operation_id_conflict"
      assert %{"deposit_paid_cents" => 2_000} = group_totals("group-81")
    end

    test "a later operation in the same batch sees the transfer" do
      results =
        submit(
          funded_pair() ++
            [
              transfer_deposit(%{"amount_cents" => 1_000}),
              record_cash_payment(%{
                "operation_id" => "op-pay-2",
                "group_id" => "group-92",
                "amount_cents" => 3_000
              })
            ]
        )

      payment = List.last(results)

      assert payment["outstanding_deposit_cents"] == 0
      assert payment["revision"] == 3
    end
  end

  defp group_totals(group_id) do
    {200, %{"data" => group}} = read_group(group_id)
    group
  end
end
