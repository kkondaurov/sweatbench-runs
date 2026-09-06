defmodule GroupStayWeb.DepositTransfersTest do
  @moduledoc """
  End-to-end coverage of the transfer_deposit operation: moving held funding
  between two active groups of one guest, the provenance the moved funding
  keeps, the statements and corrections that follow it across groups, and
  the rejection codes and ordering rules it uses.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  @zeroed %{
    "cash_held_cents" => 0,
    "cash_refunded_cents" => 0,
    "cash_retained_cents" => 0,
    "cash_converted_to_credit_cents" => 0,
    "cash_reduced_cents" => 0,
    "cash_charged_back_cents" => 0,
    "credit_liability_cents" => 0,
    "credit_shortfall_cents" => 0
  }

  defp ledger(on \\ "2026-12-01"), do: json_response(get_ledger(on), 200)["data"]

  defp group_data(group_id), do: json_response(get_group(group_id), 200)["data"]

  defp room_funding(group_id) do
    group_data(group_id)["rooms"]
    |> Map.new(&{&1["room_id"], {&1["cash_paid_cents"], &1["credit_paid_cents"]}})
  end

  defp payment_data(payment_operation_id),
    do: json_response(get_payment(payment_operation_id), 200)["data"]

  defp open_two_groups do
    post_batch([
      open_group_operation("op-1"),
      open_group_operation("op-2", %{"group_id" => "group-82"})
    ])
  end

  # group-81 and group-82 are identical: room-a needs 9_000 and room-b needs
  # 10_500, so each group's deposit due is 19_500.

  describe "moving held funding" do
    test "moves held cash in reverse draw order and fills the destination in room order" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])

      conn =
        post_batch([
          transfer_operation("op-4", "group-81", "group-82", 4_000)
        ])

      assert results(conn) == [
               %{
                 "operation_id" => "op-4",
                 "status" => "applied",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-82",
                 "amount_cents" => 4_000,
                 "source_outstanding_deposit_cents" => 11_500,
                 "destination_outstanding_deposit_cents" => 15_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ]

      # room-b's 3_000 was drawn first, then 1_000 from room-a; the drawn
      # units fill group-82's rooms in their original order
      assert room_funding("group-81") == %{"room-a" => {8_000, 0}, "room-b" => {0, 0}}
      assert room_funding("group-82") == %{"room-a" => {4_000, 0}, "room-b" => {0, 0}}

      source = group_data("group-81")
      assert source["deposit_paid_cents"] == 8_000
      assert source["outstanding_deposit_cents"] == 11_500
      assert source["revision"] == 3

      destination = group_data("group-82")
      assert destination["deposit_paid_cents"] == 4_000
      assert destination["outstanding_deposit_cents"] == 15_500
      assert destination["revision"] == 2

      # a transfer changes no ledger total
      assert ledger() == %{@zeroed | "cash_held_cents" => 12_000}
    end

    test "keeps the payment identity of moved cash in the payment statement" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      assert payment_data("op-3") == %{
               "payment_operation_id" => "op-3",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 12_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 8_000},
                 %{"group_id" => "group-82", "amount_cents" => 4_000}
               ]
             }

      # a second transfer chains: the destination becomes a source
      post_batch([transfer_operation("op-5", "group-82", "group-81", 1_500)])

      assert payment_data("op-3")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 9_500},
               %{"group_id" => "group-82", "amount_cents" => 2_500}
             ]

      assert payment_data("op-3")["held_cents"] == 12_000
    end

    test "moves hotel credit with its lot and expiry paused, restoring it later" do
      # one lot worth 11_000 expires on 2027-11-11
      post_batch([
        open_group_operation("credit-open", %{"group_id" => "group-x"}),
        pay_operation("credit-pay", "group-x", 10_000),
        cancel_operation("credit-cancel", "group-x", %{
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      ])

      open_two_groups()

      post_batch([
        # the whole lot is applied: room-a 9_000, room-b 2_000
        apply_credit_operation("op-3", "group-81", 11_000, %{"occurred_on" => "2026-11-20"}),
        # the most recent allocation — room-b's 2_000 — is drawn first
        transfer_operation("op-4", "group-81", "group-82", 2_000)
      ])

      # the credit stays applied — its expiry stays paused — and the
      # liability is unchanged by the transfer
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 0

      assert ledger() == %{
               @zeroed
               | "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
             }

      assert room_funding("group-81") == %{"room-a" => {0, 9_000}, "room-b" => {0, 0}}
      assert room_funding("group-82") == %{"room-a" => {0, 2_000}, "room-b" => {0, 0}}

      # refundable settlement of the destination restores the credit to its
      # original lot and expiry, without a second bonus
      post_batch([cancel_operation("op-5", "group-82", %{"occurred_on" => "2026-11-20"})])

      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 2_000,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-cancel",
                   "remaining_cents" => 2_000,
                   "expires_on" => "2027-11-11"
                 }
               ]
             }

      # the credit still applied to the source group keeps the rest of the
      # liability unchanged
      assert ledger() == %{
               @zeroed
               | "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
             }
    end

    test "consumes transferred credit on a non-refundable settlement" do
      post_batch([
        open_group_operation("credit-open", %{"group_id" => "group-x"}),
        pay_operation("credit-pay", "group-x", 10_000),
        cancel_operation("credit-cancel", "group-x", %{
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      ])

      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        }),
        apply_credit_operation("op-3", "group-81", 11_000, %{"occurred_on" => "2026-11-20"}),
        transfer_operation("op-4", "group-81", "group-82", 2_000),
        cancel_operation("op-5", "group-82", %{"occurred_on" => "2026-11-20"})
      ])

      # the non-refundable settlement consumes the transferred credit; the
      # credit still applied to the source group is untouched
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 0

      assert ledger() == %{
               @zeroed
               | "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 9_000
             }
    end

    test "moves mixed cash and credit while keeping their kinds apart" do
      post_batch([
        open_group_operation("credit-open", %{"group_id" => "group-x"}),
        pay_operation("credit-pay", "group-x", 10_000),
        cancel_operation("credit-cancel", "group-x", %{
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      ])

      open_two_groups()

      post_batch([
        pay_operation("op-3", "group-81", 6_000),
        apply_credit_operation("op-4", "group-81", 2_000, %{"occurred_on" => "2026-11-20"}),
        # reverse allocation order draws the credit first, then cash
        transfer_operation("op-5", "group-81", "group-82", 3_000)
      ])

      # the source keeps only its remaining cash; the destination holds the
      # drawn credit and cash on its first room
      assert room_funding("group-81") == %{"room-a" => {5_000, 0}, "room-b" => {0, 0}}
      assert room_funding("group-82") == %{"room-a" => {1_000, 2_000}, "room-b" => {0, 0}}

      source = group_data("group-81")
      assert source["deposit_paid_cents"] == 5_000
      assert source["cash_paid_cents"] == 5_000
      assert source["credit_paid_cents"] == 0

      destination = group_data("group-82")
      assert destination["deposit_paid_cents"] == 3_000
      assert destination["cash_paid_cents"] == 1_000
      assert destination["credit_paid_cents"] == 2_000

      assert ledger() == %{
               @zeroed
               | "cash_held_cents" => 6_000,
                 "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
             }
    end

    test "observes changes made by earlier operations in the same batch" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          open_group_operation("op-2", %{"group_id" => "group-82"}),
          pay_operation("op-3", "group-81", 12_000),
          transfer_operation("op-4", "group-81", "group-82", 4_000)
        ])

      result = result_for(conn, "op-4")
      assert result["status"] == "applied"
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2
    end
  end

  describe "rejections" do
    setup do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      :ok
    end

    test "rejects transfers within one group or across guests" do
      conn = post_batch([transfer_operation("op-10", "group-81", "group-81", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-10",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }

      post_batch([
        open_group_operation("op-11", %{"group_id" => "group-83", "guest_id" => "guest-33"})
      ])

      conn = post_batch([transfer_operation("op-12", "group-81", "group-83", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-12",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }
    end

    test "resolves source existence first, then destination existence" do
      conn = post_batch([transfer_operation("op-10", "group-none", "group-82", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-10",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             }

      conn = post_batch([transfer_operation("op-11", "group-81", "group-none", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-11",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             }

      # existence is resolved before any revision check
      conn =
        post_batch([
          transfer_operation("op-12", "group-81", "group-none", 100, %{
            "expected_revision" => 1
          })
        ])

      assert hd(results(conn))["code"] == "group_not_found"
    end

    test "rejects when either group is not active, naming that group" do
      post_batch([cancel_operation("op-10", "group-82", %{"occurred_on" => "2026-11-20"})])

      conn = post_batch([transfer_operation("op-11", "group-81", "group-82", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-11",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-82"
             }

      post_batch([cancel_operation("op-12", "group-81", %{"occurred_on" => "2026-11-20"})])

      conn = post_batch([transfer_operation("op-13", "group-81", "group-82", 100)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-13",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }
    end

    test "rejects unusable amounts" do
      for {amount, n} <- Enum.with_index([0, -100, "4000", nil, 50.5]) do
        conn = post_batch([transfer_operation("op-#{n + 10}", "group-81", "group-82", amount)])
        assert hd(results(conn))["code"] == "invalid_amount", inspect(amount)
      end
    end

    test "rejects amounts beyond the source's held funding or the destination's outstanding deposit" do
      conn = post_batch([transfer_operation("op-10", "group-81", "group-82", 12_001)])

      assert hd(results(conn)) == %{
               "operation_id" => "op-10",
               "status" => "rejected",
               "code" => "transfer_exceeds_held_funding"
             }

      # a transfer equal to the whole held funding is valid
      conn = post_batch([transfer_operation("op-11", "group-81", "group-82", 12_000)])
      assert hd(results(conn))["status"] == "applied"

      # group-81 now holds nothing that could be transferred
      conn = post_batch([transfer_operation("op-12", "group-81", "group-82", 1)])
      assert hd(results(conn))["code"] == "transfer_exceeds_held_funding"

      # a fully paid destination accepts no further funding
      post_batch([
        pay_operation("op-13", "group-82", 7_500),
        pay_operation("op-14", "group-81", 5_000)
      ])

      conn = post_batch([transfer_operation("op-15", "group-81", "group-82", 1)])
      assert hd(results(conn))["code"] == "transfer_exceeds_outstanding"
    end

    test "rejects an operation missing the data it needs" do
      for {overrides, n} <-
            Enum.with_index([
              %{"source_group_id" => nil},
              %{"destination_group_id" => nil},
              %{"amount_cents" => nil, "source_group_id" => 42}
            ]) do
        operation = transfer_operation("op-#{n + 10}", "group-81", "group-82", 100, overrides)

        conn = post_batch([operation])
        assert hd(results(conn))["code"] == "invalid_operation", inspect(overrides)
      end
    end
  end

  describe "revision guards" do
    setup do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      :ok
    end

    test "checks the source revision before the destination revision" do
      conn =
        post_batch([
          transfer_operation("op-10", "group-81", "group-82", 100, %{
            "expected_revision" => 1
          })
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-10",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # the source revision is checked even when the transfer rules would
      # reject the operation anyway
      post_batch([
        open_group_operation("op-11", %{"group_id" => "group-83", "guest_id" => "guest-33"})
      ])

      conn =
        post_batch([
          transfer_operation("op-12", "group-81", "group-83", 100, %{
            "expected_revision" => 1
          })
        ])

      assert hd(results(conn))["code"] == "stale_revision"

      # a matching source guard is accepted
      conn =
        post_batch([
          transfer_operation("op-13", "group-81", "group-82", 100, %{
            "expected_revision" => 2
          })
        ])

      assert hd(results(conn))["status"] == "applied"
    end

    test "guards the destination revision with its own field" do
      conn =
        post_batch([
          transfer_operation("op-10", "group-81", "group-82", 100, %{
            "destination_expected_revision" => 99
          })
        ])

      assert hd(results(conn)) == %{
               "operation_id" => "op-10",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-82",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      # the destination guard is checked before the transfer rules
      conn =
        post_batch([
          transfer_operation("op-11", "group-81", "group-81", 100, %{
            "destination_expected_revision" => 99
          })
        ])

      assert hd(results(conn))["code"] == "stale_revision"

      conn =
        post_batch([
          transfer_operation("op-12", "group-81", "group-82", 100, %{
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["source_revision"] == 3
      assert hd(results(conn))["destination_revision"] == 2
    end

    test "a rejected transfer does not advance any revision" do
      post_batch([transfer_operation("op-10", "group-81", "group-82", 12_001)])

      assert group_data("group-81")["revision"] == 2
      assert group_data("group-82")["revision"] == 1
    end
  end

  describe "durable idempotency" do
    test "a retry returns the exact stored result without moving funding again" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])

      operation = transfer_operation("op-4", "group-81", "group-82", 4_000)
      original = hd(results(post_batch([operation])))
      assert original["status"] == "applied"

      assert results(post_batch([operation])) == [original]

      assert room_funding("group-81") == %{"room-a" => {8_000, 0}, "room-b" => {0, 0}}
      assert room_funding("group-82") == %{"room-a" => {4_000, 0}, "room-b" => {0, 0}}
      assert group_data("group-81")["revision"] == 3
      assert group_data("group-82")["revision"] == 2

      # the stored result is also exposed by the operations endpoint
      assert json_response(get_operation("op-4"), 200)["data"] == original
    end

    test "a different payload under the same identifier conflicts" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])

      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      conn = post_batch([transfer_operation("op-4", "group-81", "group-82", 3_000)])

      assert hd(results(conn))["code"] == "operation_id_conflict"
      assert room_funding("group-82") == %{"room-a" => {4_000, 0}, "room-b" => {0, 0}}
    end

    test "a rejected transfer is remembered like an applied one" do
      open_two_groups()

      operation = transfer_operation("op-10", "group-81", "group-82", 1)
      original = hd(results(post_batch([operation])))
      assert original["code"] == "transfer_exceeds_held_funding"

      assert results(post_batch([operation])) == [original]
    end
  end

  describe "later settlement" do
    test "transferred cash converts to hotel credit under the destination policy" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      conn =
        post_batch([
          cancel_operation("op-5", "group-82", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      # the existing bonus rule applies to the cash settled there
      assert hd(results(conn))["credit_issued_cents"] == 4_400

      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"][
               "available_cents"
             ] == 4_400

      # the payment's statement follows its funding to the destination
      assert payment_data("op-3") == %{
               "payment_operation_id" => "op-3",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 8_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 4_000,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 8_000}]
             }

      assert ledger() == %{
               @zeroed
               | "cash_held_cents" => 8_000,
                 "cash_converted_to_credit_cents" => 4_000,
                 "credit_liability_cents" => 4_400
             }
    end

    test "transferred cash is retained when the destination policy is non-refundable" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        }),
        pay_operation("op-3", "group-81", 12_000),
        transfer_operation("op-4", "group-81", "group-82", 4_000),
        cancel_operation("op-5", "group-82", %{"occurred_on" => "2026-11-20"})
      ])

      assert ledger() == %{
               @zeroed
               | "cash_held_cents" => 8_000,
                 "cash_retained_cents" => 4_000
             }

      assert payment_data("op-3")["retained_cents"] == 4_000

      assert payment_data("op-3")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_000}
             ]
    end

    test "a reduction follows the payment's allocations across groups" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      conn = post_batch([reduce_cash_operation("op-5", "op-3", 4_500)])

      # the most recently created allocations — the destination's — are
      # removed first: all 4_000 from group-82, then 500 from group-81
      assert hd(results(conn)) == %{
               "operation_id" => "op-5",
               "status" => "applied",
               "payment_operation_id" => "op-3",
               "group_id" => "group-81",
               "amount_cents" => 4_500,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 4
             }

      assert room_funding("group-81") == %{"room-a" => {7_500, 0}, "room-b" => {0, 0}}
      assert room_funding("group-82") == %{"room-a" => {0, 0}, "room-b" => {0, 0}}

      # every group whose funding state changed increments its revision
      assert group_data("group-81")["revision"] == 4
      assert group_data("group-82")["revision"] == 3

      assert group_data("group-81")["outstanding_deposit_cents"] == 12_000
      assert group_data("group-82")["outstanding_deposit_cents"] == 19_500

      assert ledger() == %{@zeroed | "cash_held_cents" => 7_500, "cash_reduced_cents" => 4_500}

      # groups holding none of the payment's cash are omitted
      assert payment_data("op-3")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7_500}
             ]

      assert payment_data("op-3")["reduced_cents"] == 4_500
    end

    test "a reduction follows cash still held in the destination after the source was cancelled" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      # the source settles its remaining held cash; the transferred cash
      # stays held in the destination
      post_batch([cancel_operation("op-5", "group-81", %{"occurred_on" => "2026-11-20"})])

      conn = post_batch([reduce_cash_operation("op-6", "op-3", 1_000)])

      assert hd(results(conn))["status"] == "applied"
      assert hd(results(conn))["amount_cents"] == 1_000
      assert hd(results(conn))["outstanding_deposit_cents"] == 0

      # the reduction removes the cash still held in the destination
      assert room_funding("group-82") == %{"room-a" => {3_000, 0}, "room-b" => {0, 0}}
      assert group_data("group-82")["revision"] == 3

      # the cancelled addressed group records the correction and advances
      # its revision, without reopening its deposit
      data = group_data("group-81")
      assert data["status"] == "cancelled"
      assert data["revision"] == 5
      assert data["outstanding_deposit_cents"] == 0

      assert payment_data("op-3") == %{
               "payment_operation_id" => "op-3",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 3_000,
               "refunded_cents" => 8_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0,
               "held_by_group" => [%{"group_id" => "group-82", "amount_cents" => 3_000}]
             }

      assert ledger() == %{
               @zeroed
               | "cash_held_cents" => 3_000,
                 "cash_refunded_cents" => 8_000,
                 "cash_reduced_cents" => 1_000
             }
    end

    test "a chargeback follows the payment's allocations across groups" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      conn = post_batch([charge_back_operation("op-5", "op-3")])

      assert hd(results(conn)) == %{
               "operation_id" => "op-5",
               "status" => "applied",
               "payment_operation_id" => "op-3",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      assert room_funding("group-81") == %{"room-a" => {0, 0}, "room-b" => {0, 0}}
      assert room_funding("group-82") == %{"room-a" => {0, 0}, "room-b" => {0, 0}}

      # both groups whose funding changed increment their revisions
      assert group_data("group-81")["revision"] == 4
      assert group_data("group-82")["revision"] == 3

      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 12_000}

      # after none remains, the statement returns an empty list
      assert payment_data("op-3")["held_by_group"] == []
      assert payment_data("op-3")["charged_back_cents"] == 12_000
    end

    test "a chargeback reclassifies a conversion made in the destination group" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])
      post_batch([transfer_operation("op-4", "group-81", "group-82", 4_000)])

      # the transferred cash converts to hotel credit under the
      # destination's policy
      post_batch([
        cancel_operation("op-5", "group-82", %{
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      ])

      conn = post_batch([charge_back_operation("op-6", "op-3")])

      assert hd(results(conn))["charged_back_cents"] == 12_000

      # the conversion is reclassified in the destination group and the
      # entitlement it created is revoked
      assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"]["lots"] == []

      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 12_000}

      assert payment_data("op-3") == %{
               "payment_operation_id" => "op-3",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 12_000,
               "held_by_group" => []
             }

      # both groups whose funding state changed increment their revisions
      assert group_data("group-81")["revision"] == 4
      assert group_data("group-82")["revision"] == 4
    end

    test "a chargeback works when the addressed group holds none of the payment's cash" do
      open_two_groups()
      post_batch([pay_operation("op-3", "group-81", 12_000)])

      # the whole payment now funds the destination's rooms
      post_batch([transfer_operation("op-4", "group-81", "group-82", 12_000)])

      conn = post_batch([charge_back_operation("op-5", "op-3")])

      assert hd(results(conn)) == %{
               "operation_id" => "op-5",
               "status" => "applied",
               "payment_operation_id" => "op-3",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      assert room_funding("group-82") == %{"room-a" => {0, 0}, "room-b" => {0, 0}}
      assert group_data("group-82")["deposit_paid_cents"] == 0

      # the addressed group's revision advances exactly once even though its
      # own funding was untouched
      assert group_data("group-81")["revision"] == 4
      assert group_data("group-82")["revision"] == 3

      assert ledger() == %{@zeroed | "cash_charged_back_cents" => 12_000}
    end
  end
end
