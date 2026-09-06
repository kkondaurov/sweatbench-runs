defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  alias GroupStay.Groups

  # Opens group-81 and group-82 for guest-22, each owing 19_500.
  defp open_two_groups!(conn, overrides \\ %{}) do
    apply_batch!(conn, [
      open_group_op(),
      open_group_op(Map.merge(%{"operation_id" => "op-82", "group_id" => "group-82"}, overrides))
    ])
  end

  # Fully funds default group-81 with one payment.
  defp fund_source!(conn, amount \\ 10_000) do
    apply_batch!(conn, [
      open_group_op(),
      record_cash_payment_op(%{"amount_cents" => amount})
    ])
  end

  describe "moving held funding" do
    test "moves funding and reports both groups' outstanding and revisions", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      [result] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{"amount_cents" => 7_000})
        ])

      assert result == %{
               "operation_id" => "op-9001",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-82",
               "amount_cents" => 7_000,
               "source_outstanding_deposit_cents" => 16_500,
               "destination_outstanding_deposit_cents" => 12_500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      assert get_group!(fresh_conn(), "group-81")["deposit_paid_cents"] == 3_000
      assert get_group!(fresh_conn(), "group-82")["deposit_paid_cents"] == 7_000
    end

    test "draws most recent allocations first and fills destination rooms in order", %{conn: conn} do
      # 10_000 fills source room-a (due 9_000) and room-b (1_000). Drawing
      # 7_000 takes room-b's 1_000 first (most recently created), then 6_000
      # of room-a 9_000. The destination's room-a fills with 1_000 and 6_000
      # in draw order; the source keeps 3_000 on room-a.
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      [result] =
        post_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 7_000})])

      assert result["status"] == "applied"

      source = get_group!(fresh_conn(), "group-81")
      assert Enum.map(source["rooms"], & &1["cash_paid_cents"]) == [3_000, 0]

      destination = get_group!(fresh_conn(), "group-82")
      assert Enum.map(destination["rooms"], & &1["cash_paid_cents"]) == [7_000, 0]
    end

    test "moves hotel credit without resuming its expiry, keeping its original lot", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        open_group_op(%{"operation_id" => "op-83", "group_id" => "group-83"})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{
            "source_group_id" => "group-82",
            "destination_group_id" => "group-83",
            "amount_cents" => 9_000
          })
        ])

      assert result["status"] == "applied"

      destination = get_group!(fresh_conn(), "group-83")
      assert destination["credit_paid_cents"] == 9_000
      assert destination["cash_paid_cents"] == 0

      # The transfer does not resume the credit's expiry; the remaining
      # 12_450 is still available.
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 12_450
    end

    test "changes no ledger total", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      before = get_ledger!(fresh_conn())

      apply_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 7_000})])

      assert get_ledger!(fresh_conn()) == before
    end

    test "transfers are durably idempotent", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      op = transfer_deposit_op(%{"amount_cents" => 7_000})
      [original] = post_batch!(fresh_conn(), [op])

      [replay] = post_batch!(fresh_conn(), [op])
      assert replay == original

      assert get_group!(fresh_conn(), "group-82")["deposit_paid_cents"] == 7_000
      assert get_group!(fresh_conn(), "group-81")["deposit_paid_cents"] == 3_000
    end

    test "same-batch operations observe each other's changes", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 10_000}),
          open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
          transfer_deposit_op(%{"amount_cents" => 7_000})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]
    end
  end

  describe "transfer validations" do
    test "resolves source existence first, then destination existence", %{conn: conn} do
      [result] = post_batch!(conn, [transfer_deposit_op()])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-81"

      fund_source!(conn)

      [result] =
        post_batch!(fresh_conn(), [transfer_deposit_op(%{"operation_id" => "op-9002"})])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-82"
    end

    test "rejects transfers between the same group or between different guests", %{conn: conn} do
      fund_source!(conn)

      [same] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{"destination_group_id" => "group-81"})
        ])

      assert same["code"] == "invalid_transfer"

      apply_batch!(fresh_conn(), [
        open_group_op(%{
          "operation_id" => "op-82",
          "group_id" => "group-82",
          "guest_id" => "guest-99"
        })
      ])

      [other_guest] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{"operation_id" => "op-9002"})
        ])

      assert other_guest["code"] == "invalid_transfer"
    end

    test "rejects inactive groups and names the inactive group", %{conn: conn} do
      fund_source!(conn)
      open_two_groups!(conn)

      apply_batch!(fresh_conn(), [cancel_group_op()])

      [source_inactive] = post_batch!(fresh_conn(), [transfer_deposit_op()])

      assert source_inactive["code"] == "group_not_active"
      assert source_inactive["group_id"] == "group-81"

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-81b", "group_id" => "group-91"}),
        cancel_group_op(%{"operation_id" => "op-91c", "group_id" => "group-82"})
      ])

      [destination_inactive] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{
            "operation_id" => "op-9002",
            "source_group_id" => "group-91"
          })
        ])

      assert destination_inactive["code"] == "group_not_active"
      assert destination_inactive["group_id"] == "group-82"
    end

    test "rejects non-positive amounts", %{conn: conn} do
      fund_source!(conn)
      open_two_groups!(conn)

      for {amount, index} <- Enum.with_index([0, -1, "7000", 3.5]) do
        [result] =
          post_batch!(fresh_conn(), [
            transfer_deposit_op(%{"operation_id" => "op-amt-#{index}", "amount_cents" => amount})
          ])

        assert result["code"] == "invalid_amount", "amount=#{inspect(amount)}"
      end
    end

    test "rejects amounts above the source's held funding and the destination's outstanding", %{
      conn: conn
    } do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 5_000}),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"})
      ])

      [exceeds_held] =
        post_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 5_001})])

      assert exceeds_held["code"] == "transfer_exceeds_held_funding"

      # With the destination owing less than the source holds, the
      # outstanding check fires.
      apply_batch!(fresh_conn(), [
        record_cash_payment_op(%{
          "operation_id" => "op-pay-more",
          "amount_cents" => 14_500
        })
      ])

      assert Groups.get_group("group-81").deposit_paid_cents == 19_500

      apply_batch!(fresh_conn(), [
        record_cash_payment_op(%{
          "operation_id" => "op-pay-dest",
          "group_id" => "group-82",
          "amount_cents" => 19_000
        })
      ])

      [exceeds_outstanding] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{
            "operation_id" => "op-9002",
            "amount_cents" => 501
          })
        ])

      assert exceeds_outstanding["code"] == "transfer_exceeds_outstanding"
    end

    test "checks source revision, then destination revision", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      [result] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{
            "amount_cents" => 7_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])

      assert result["status"] == "applied"

      [stale_source] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{
            "operation_id" => "op-9002",
            "amount_cents" => 7_000,
            "expected_revision" => 2
          })
        ])

      assert stale_source["code"] == "stale_revision"
      assert stale_source["group_id"] == "group-81"
      assert stale_source["actual_revision"] == 3

      [stale_destination] =
        post_batch!(fresh_conn(), [
          transfer_deposit_op(%{
            "operation_id" => "op-9003",
            "amount_cents" => 7_000,
            "destination_expected_revision" => 1
          })
        ])

      assert stale_destination["code"] == "stale_revision"
      assert stale_destination["group_id"] == "group-82"
      assert stale_destination["actual_revision"] == 2
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination's policy with the bonus", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      apply_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 10_000})])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 11_000

      # The original payment's cash moved to converted; the recorded batch
      # continues.
      statement = get_payment!(fresh_conn(), "op-2001")
      assert statement["converted_to_credit_cents"] == 10_000
      assert statement["held_cents"] == 0
    end

    test "transferred credit returns to its original lot without another bonus", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        open_group_op(%{"operation_id" => "op-83", "group_id" => "group-83"}),
        transfer_deposit_op(%{
          "operation_id" => "op-tr",
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 9_000
        })
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "operation_id" => "op-cancel-83",
            "group_id" => "group-83",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 0

      # The applied 9_000 returns to its original lot with its original
      # expiry, and receives no second bonus.
      assert get_credit!(fresh_conn(), "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "op-4001",
                 "remaining_cents" => 21_450,
                 "expires_on" => "2027-11-02"
               }
             ]
    end

    test "reductions follow a payment's allocations across groups", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      apply_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 2_000})])

      # The payment funds group-81 with 8_000 and group-82 with 2_000. A
      # reduction removes the most recently created allocations first: the
      # transferred 2_000 on group-82, then 1_000 of group-81's funding.
      [result] =
        post_batch!(fresh_conn(), [
          reduce_cash_payment_op(%{"amount_cents" => 3_000})
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 4

      source = get_group!(fresh_conn(), "group-81")
      destination = get_group!(fresh_conn(), "group-82")

      assert source["deposit_paid_cents"] == 7_000
      assert destination["deposit_paid_cents"] == 0
      assert source["revision"] == 4
      assert destination["revision"] == 3
    end

    test "chargebacks follow a payment's allocations across groups", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      apply_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 2_000})])

      [result] = post_batch!(fresh_conn(), [charge_back_payment_op()])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_000
      assert result["revision"] == 4

      assert get_group!(fresh_conn(), "group-81")["revision"] == 4
      assert get_group!(fresh_conn(), "group-82")["revision"] == 3
      assert get_group!(fresh_conn(), "group-82")["deposit_paid_cents"] == 0
      assert get_group!(fresh_conn(), "group-81")["deposit_paid_cents"] == 0
    end

    test "a payment statement gains held_by_group once funding moves", %{conn: conn} do
      fund_source!(conn, 10_000)
      open_two_groups!(conn)

      assert get_payment!(fresh_conn(), "op-2001")["held_by_group"] == nil

      apply_batch!(fresh_conn(), [transfer_deposit_op(%{"amount_cents" => 2_000})])

      statement = get_payment!(fresh_conn(), "op-2001")

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_000},
               %{"group_id" => "group-82", "amount_cents" => 2_000}
             ]

      assert statement["held_cents"] == 10_000

      # After the destination settles, only groups with held cash remain.
      apply_batch!(fresh_conn(), [
        cancel_group_op(%{"operation_id" => "op-cancel-82", "group_id" => "group-82"})
      ])

      assert get_payment!(fresh_conn(), "op-2001")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_000}
             ]

      # And once nothing remains held, the list is empty.
      apply_batch!(fresh_conn(), [
        charge_back_payment_op(%{"operation_id" => "op-charge"})
      ])

      assert get_payment!(fresh_conn(), "op-2001")["held_by_group"] == []
    end
  end
end
