defmodule GroupStayWeb.Acceptance.DepositTransferTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # Two rooms over two nights (flexible, 20% deposit):
  #   room-a lodging 20000 deposit 4000
  #   room-b lodging 30000 deposit 6000
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000}
        ]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp transfer_op(op_id, source_group_id, destination_group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp cancel_op(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp apply_credit_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp reduce_op(op_id, payment_operation_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp charge_back_op(op_id, payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  # Cancels a helper group refundably into hotel credit so the guest has a lot:
  # 4000 cash becomes a 4400 lot expiring 2027-11-02.
  defp issue_lot(conn) do
    submit(conn, [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

    submit(conn, [
      cancel_op("group-c", "2026-11-01", %{"refund_method" => "hotel_credit"})
    ])
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, on) do
    conn
    |> get("/api/v1/guests/#{@guest}/credit", %{"on" => on})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "applying a transfer" do
    test "moves held cash between two active groups of the same guest" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      ledger_before = ledger(build_conn())

      assert [
               %{
                 "operation_id" => "transfer-1",
                 "status" => "applied",
                 "source_group_id" => "group-a",
                 "destination_group_id" => "group-b",
                 "amount_cents" => 3000,
                 "source_outstanding_deposit_cents" => 6000,
                 "destination_outstanding_deposit_cents" => 7000,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      source = group(build_conn(), "group-a")
      assert source["deposit_paid_cents"] == 4000
      assert source["outstanding_deposit_cents"] == 6000
      assert source["revision"] == 3

      destination = group(build_conn(), "group-b")
      assert destination["deposit_paid_cents"] == 3000
      assert destination["outstanding_deposit_cents"] == 7000
      assert destination["revision"] == 2

      # Room-level funding follows the moved cash.
      [source_room_a, source_room_b] = source["rooms"]
      assert source_room_a["cash_paid_cents"] == 4000
      assert source_room_b["cash_paid_cents"] == 0

      [destination_room_a, destination_room_b] = destination["rooms"]
      assert destination_room_a["cash_paid_cents"] == 3000
      assert destination_room_b["cash_paid_cents"] == 0

      # A transfer changes no ledger total.
      assert ledger(build_conn()) == ledger_before
    end

    test "draws from the source in reverse allocation order regardless of kind" do
      issue_lot(build_conn())
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 4000)])
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])

      # Source holds cash 4000 on room-a and credit 2000 on room-b; the credit
      # was allocated most recently, so it is drawn first.
      assert [%{"status" => "applied", "amount_cents" => 3000}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      source = group(build_conn(), "group-a")
      [source_room_a, source_room_b] = source["rooms"]
      assert source_room_a["cash_paid_cents"] == 3000
      assert source_room_b["cash_paid_cents"] == 0
      assert source_room_b["credit_paid_cents"] == 0

      destination = group(build_conn(), "group-b")
      [destination_room_a, _destination_room_b] = destination["rooms"]
      assert destination_room_a["cash_paid_cents"] == 1000
      assert destination_room_a["credit_paid_cents"] == 2000

      assert destination["deposit_paid_cents"] == 3000
      assert destination["credit_paid_cents"] == 2000
    end

    test "fills the destination's rooms in their original order preserving draw order" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 5000), pay_op("pay-2", "group-a", 3000)])

      # Draw order: pay-2's 3000 (newest), then pay-1's room-b 1000, then
      # pay-1's room-a 1000. The destination fills room-a before room-b.
      assert [%{"status" => "applied"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 5000)])

      destination = group(build_conn(), "group-b")
      [room_a, room_b] = destination["rooms"]
      assert room_a["cash_paid_cents"] == 4000
      assert room_b["cash_paid_cents"] == 1000

      source = group(build_conn(), "group-a")
      [source_room_a, source_room_b] = source["rooms"]
      assert source_room_a["cash_paid_cents"] == 3000
      assert source_room_b["cash_paid_cents"] == 0

      # pay-1's remaining held cash spans both groups.
      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 5000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-a", "amount_cents" => 3000},
               %{"group_id" => "group-b", "amount_cents" => 2000}
             ]
    end

    test "held funding counts cash and hotel credit" do
      issue_lot(build_conn())
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 2000)])
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 1000)])

      assert [%{"status" => "applied", "amount_cents" => 3000}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 0
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 3000
    end

    test "a complete held-funding move empties the source" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      assert [%{"status" => "applied", "source_outstanding_deposit_cents" => 10000}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 7000)])

      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 0
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 7000
    end

    test "operations in one batch see each other's changes" do
      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2}
             ] =
               submit(build_conn(), [
                 open_op("group-a"),
                 open_op("group-b"),
                 pay_op("pay-1", "group-a", 7000),
                 transfer_op("transfer-1", "group-a", "group-b", 3000)
               ])
    end
  end

  describe "provenance" do
    test "transferred cash keeps its payment identity for reductions" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 5000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      # Reducing pay-1 removes the transferred cash (the newest allocations)
      # first, even though it now funds another group.
      assert [%{"status" => "applied", "group_id" => "group-a", "revision" => 4}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 2500)])

      source = group(build_conn(), "group-a")
      assert source["deposit_paid_cents"] == 2500
      assert source["outstanding_deposit_cents"] == 7500

      destination = group(build_conn(), "group-b")
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 10000
      # The destination's revision increments even though the reduction was
      # not addressed to it.
      assert destination["revision"] == 3

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 2500
      assert statement["reduced_cents"] == 2500

      assert statement["held_by_group"] == [
               %{"group_id" => "group-a", "amount_cents" => 2500}
             ]

      assert ledger(build_conn())["cash_reduced_cents"] == 2500
    end

    test "a chargeback follows transferred cash across groups" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 5000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-a",
                 "charged_back_cents" => 5000,
                 "outstanding_deposit_cents" => 10000,
                 "revision" => 4
               }
             ] = submit(build_conn(), [charge_back_op("cb-1", "pay-1")])

      source = group(build_conn(), "group-a")
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 10000

      destination = group(build_conn(), "group-b")
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 10000
      assert destination["revision"] == 3

      assert ledger(build_conn())["cash_held_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 5000
    end

    test "reductions remain guarded only by the addressed group's revision" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 5000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      # group-a is at revision 3, group-b at revision 2; the reduction checks
      # only the addressed group.
      assert [%{"status" => "applied", "revision" => 4}] =
               submit(build_conn(), [
                 reduce_op("reduce-1", "pay-1", 1000, %{"expected_revision" => 3})
               ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-a",
                 "expected_revision" => 3,
                 "actual_revision" => 4
               }
             ] =
               submit(build_conn(), [
                 reduce_op("reduce-2", "pay-1", 1000, %{"expected_revision" => 3})
               ])
    end

    test "the addressed group still increments its revision when nothing is removed from it" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 5000)
      ])

      # All of pay-1's held cash now funds group-b.
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 5000)])

      assert [%{"status" => "applied", "group_id" => "group-a", "revision" => 4}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 1000)])

      # The addressed group's state is unchanged but its revision advanced.
      source = group(build_conn(), "group-a")
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 10000
      assert source["revision"] == 4

      destination = group(build_conn(), "group-b")
      assert destination["deposit_paid_cents"] == 4000
      assert destination["revision"] == 3
    end

    test "returned funding is removed before earlier allocations of the same payment" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 4000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])
      submit(build_conn(), [transfer_op("transfer-2", "group-b", "group-a", 1000)])

      # pay-1 now holds 2000 original and 1000 returned on group-a plus 1000
      # on group-b; the returned portion is the newest allocation.
      assert [%{"status" => "applied"}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 1000)])

      source = group(build_conn(), "group-a")
      assert source["deposit_paid_cents"] == 2000

      # The destination's funding is untouched.
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 1000

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 3000
      assert statement["reduced_cents"] == 1000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-a", "amount_cents" => 2000},
               %{"group_id" => "group-b", "amount_cents" => 1000}
             ]
    end

    test "transferred hotel credit keeps its original lot with expiry paused" do
      issue_lot(build_conn())
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])

      assert guest_credit(build_conn(), "2026-11-02")["available_cents"] == 2400
      ledger_before = ledger(build_conn())

      assert [%{"status" => "applied"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      # The transfer neither resumes expiry nor revalues the credit.
      assert guest_credit(build_conn(), "2026-11-02")["available_cents"] == 2400
      assert ledger(build_conn()) == ledger_before

      assert group(build_conn(), "group-b")["credit_paid_cents"] == 2000
      assert group(build_conn(), "group-a")["credit_paid_cents"] == 0

      # A refundable settlement of the destination restores the credit to its
      # original lot and expiry without another bonus.
      assert [%{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0}] =
               submit(build_conn(), [cancel_op("group-b", "2026-11-20")])

      credit = guest_credit(build_conn(), "2026-11-20")
      assert credit["available_cents"] == 4400

      assert [
               %{
                 "source_operation_id" => "cancel-group-c",
                 "remaining_cents" => 4400,
                 "expires_on" => "2027-11-02"
               }
             ] = credit["lots"]
    end

    test "restored transferred credit follows the existing expiry rules" do
      issue_lot(build_conn())

      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{
          "arrival_on" => "2028-01-10",
          "departure_on" => "2028-01-12"
        })
      ])

      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      # Settling the destination refundably after the lot's expiry restores
      # the credit to an expired lot; it expires immediately.
      assert [%{"status" => "applied"}] =
               submit(build_conn(), [cancel_op("group-b", "2027-11-05")])

      assert guest_credit(build_conn(), "2027-11-05")["available_cents"] == 0

      ledger_conn = build_conn()

      assert get(ledger_conn, "/api/v1/ledger", %{"on" => "2027-11-05"})
             |> json_response(200)
             |> Map.fetch!("data")
             |> Map.fetch!("credit_liability_cents") == 0
    end

    test "a restoration of transferred credit is absorbed by the lot's shortfall" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 3000)])

      # Charging pay-c back leaves a 3000 clawback on the lot, covered by the
      # credit still applied to group-a.
      submit(build_conn(), [
        charge_back_op("cb-c", "pay-c", %{"occurred_on" => "2026-11-03"})
      ])

      assert ledger(build_conn())["credit_shortfall_cents"] == 3000
      assert ledger(build_conn())["credit_liability_cents"] == 3000

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      # The transfer changes no credit total.
      assert ledger(build_conn())["credit_shortfall_cents"] == 3000
      assert ledger(build_conn())["credit_liability_cents"] == 3000

      # Restoring the transferred credit extinguishes the shortfall before any
      # amount becomes available.
      submit(build_conn(), [cancel_op("group-b", "2026-11-20")])

      assert guest_credit(build_conn(), "2026-11-20")["available_cents"] == 0
      assert ledger(build_conn())["credit_shortfall_cents"] == 0
      assert ledger(build_conn())["credit_liability_cents"] == 0
    end

    test "non-refundable settlement consumes transferred credit normally" do
      issue_lot(build_conn())
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      assert ledger(build_conn())["credit_liability_cents"] == 4400

      # A non-refundable settlement of the destination consumes the credit.
      assert [%{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0}] =
               submit(build_conn(), [cancel_op("group-b", "2026-12-05")])

      assert guest_credit(build_conn(), "2026-12-05")["available_cents"] == 2400
      assert ledger(build_conn())["credit_liability_cents"] == 2400
    end

    test "transferred cash settles under the destination's policy when retained" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }),
        pay_op("pay-1", "group-a", 5000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 5000)])

      # Advance purchase is always non-refundable.
      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5000}] =
               submit(build_conn(), [cancel_op("group-b", "2026-11-01")])

      assert ledger(build_conn())["cash_retained_cents"] == 5000
      assert ledger(build_conn())["cash_held_cents"] == 0

      # The source group is untouched.
      assert group(build_conn(), "group-a")["revision"] == 3
    end

    test "cash converted at the destination receives the bonus there" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 5000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 5000)])

      assert [%{"status" => "applied", "credit_issued_cents" => 5500}] =
               submit(build_conn(), [
                 cancel_op("group-b", "2026-11-01", %{"refund_method" => "hotel_credit"})
               ])

      assert ledger(build_conn())["cash_converted_to_credit_cents"] == 5000
      assert guest_credit(build_conn(), "2026-11-01")["available_cents"] == 5500
    end
  end

  describe "payment statement evolution" do
    test "held_by_group appears once funding from the payment has transferred" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 5000)
      ])

      # Before any transfer the earlier statement shape is retained.
      refute Map.has_key?(payment(build_conn(), "pay-1"), "held_by_group")

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 5000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-a", "amount_cents" => 3000},
               %{"group_id" => "group-b", "amount_cents" => 2000}
             ]

      # Moving the remainder omits groups with no held cash.
      submit(build_conn(), [transfer_op("transfer-2", "group-a", "group-b", 3000)])

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 5000
      assert statement["held_by_group"] == [%{"group_id" => "group-b", "amount_cents" => 5000}]

      # After none remains, the list is empty but present.
      submit(build_conn(), [cancel_op("group-b", "2026-11-01")])

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 0
      assert statement["refunded_cents"] == 5000
      assert statement["held_by_group"] == []
    end

    test "the held_by_group amounts sum to held_cents" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2500)])

      statement = payment(build_conn(), "pay-1")
      total = Enum.reduce(statement["held_by_group"], 0, &(&1["amount_cents"] + &2))
      assert total == statement["held_cents"]
    end
  end

  describe "rejections" do
    test "invalid_transfer when the groups are the same" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-a", 1000)])
    end

    test "invalid_transfer when the groups have different guests" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-x", %{"guest_id" => "guest-99"}),
        pay_op("pay-1", "group-a", 7000)
      ])

      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-x", 1000)])
    end

    test "invalid_transfer is checked before activity" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-x", %{"guest_id" => "guest-99"})
      ])

      submit(build_conn(), [cancel_op("group-a", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-x", 1000)])
    end

    test "group_not_active for an inactive source carries its group_id" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [cancel_op("group-a", "2026-11-01")])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "group-a"
               }
             ] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 1000)])
    end

    test "group_not_active for an inactive destination carries its group_id" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 7000)])
      submit(build_conn(), [cancel_op("group-b", "2026-11-01")])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "group-b"
               }
             ] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 1000)])
    end

    test "invalid_amount when the amount is not positive" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])

      [0, -100, "1000", 10.5]
      |> Enum.with_index()
      |> Enum.each(fn {amount, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(build_conn(), [
                   transfer_op("transfer-invalid-#{index}", "group-a", "group-b", 1000, %{
                     "amount_cents" => amount
                   })
                 ])
      end)
    end

    test "a missing amount is an invalid operation" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 transfer_op("transfer-1", "group-a", "group-b", 1000)
                 |> Map.delete("amount_cents")
               ])
    end

    test "activity is checked before the amount" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [cancel_op("group-a", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 0)])
    end

    test "the amount is checked before the funding limits" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])

      assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 0)])
    end

    test "transfer_exceeds_held_funding when the source holds less than requested" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 3000)])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3001)])

      # Nothing moved.
      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 3000
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 0
    end

    test "transfer_exceeds_outstanding when the destination owes less than requested" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 10000),
        pay_op("pay-2", "group-b", 8000)
      ])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_outstanding"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 10000
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 8000
    end

    test "the source held-funding limit is checked before the destination limit" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 1000),
        pay_op("pay-2", "group-b", 9000)
      ])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])
    end

    test "a missing source is reported first, with its group_id" do
      submit(build_conn(), [open_op("group-b")])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-a"
               }
             ] =
               submit(build_conn(), [transfer_op("transfer-1", "missing-a", "group-b", 1000)])
    end

    test "a missing destination is reported with its group_id" do
      submit(build_conn(), [open_op("group-a")])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-b"
               }
             ] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "missing-b", 1000)])
    end

    test "the source revision is checked before the destination revision" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-a",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ] =
               submit(build_conn(), [
                 transfer_op("transfer-1", "group-a", "group-b", 1000, %{
                   "expected_revision" => 99,
                   "destination_expected_revision" => 99
                 })
               ])
    end

    test "a destination revision mismatch uses stale_revision with its details" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-b",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ] =
               submit(build_conn(), [
                 transfer_op("transfer-1", "group-a", "group-b", 1000, %{
                   "destination_expected_revision" => 99
                 })
               ])
    end

    test "matching revisions are accepted for both groups" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      assert [%{"status" => "applied", "source_revision" => 3, "destination_revision" => 2}] =
               submit(build_conn(), [
                 transfer_op("transfer-1", "group-a", "group-b", 1000, %{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 1
                 })
               ])
    end

    test "revisions are checked before the transfer rules" do
      submit(build_conn(), [open_op("group-a")])

      assert [%{"status" => "rejected", "code" => "stale_revision"}] =
               submit(build_conn(), [
                 transfer_op("transfer-1", "group-a", "group-a", 1000, %{
                   "expected_revision" => 99
                 })
               ])
    end

    test "a rejected transfer changes nothing and does not advance revisions" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])

      assert [%{"status" => "rejected"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 1000)])

      assert group(build_conn(), "group-a")["revision"] == 1
      assert group(build_conn(), "group-b")["revision"] == 1
      assert ledger(build_conn())["cash_held_cents"] == 0
    end
  end

  describe "durability" do
    test "a retry returns the stored result without moving funding again" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      [first] = submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])
      assert first["status"] == "applied"

      assert submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)]) ==
               [first]

      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 4000
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 3000
      assert group(build_conn(), "group-a")["revision"] == 3
      assert group(build_conn(), "group-b")["revision"] == 2
    end

    test "a rejected transfer is remembered even when it later could apply" do
      submit(build_conn(), [open_op("group-a"), open_op("group-b")])

      [rejected] = submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])
      assert rejected["status"] == "rejected"
      assert rejected["code"] == "transfer_exceeds_held_funding"

      submit(build_conn(), [pay_op("pay-1", "group-a", 7000)])

      assert submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)]) ==
               [rejected]

      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 7000
    end

    test "reusing the identifier with a different payload is a conflict" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b"),
        pay_op("pay-1", "group-a", 7000)
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      # The original transfer still took effect exactly once.
      assert group(build_conn(), "group-b")["deposit_paid_cents"] == 3000
    end
  end
end
