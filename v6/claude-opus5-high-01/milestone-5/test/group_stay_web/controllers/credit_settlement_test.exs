defmodule GroupStayWeb.CreditSettlementTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # group-82 arrives 2027-02-10 under a flex-14 policy, so 2027-01-27 is its last
  # refundable day. It is funded by 11_000 of credit from cancel-17, whose lot is
  # available through 2027-11-26.
  @refundable_on "2027-01-27"
  @too_late_on "2027-01-28"

  setup %{conn: conn} do
    submit(conn, [
      open_group_op(),
      payment_op(),
      cancel_op(%{
        operation_id: "cancel-17",
        occurred_on: "2026-11-26",
        refund_method: "hotel_credit"
      }),
      open_group_op(%{
        operation_id: "op-open-2",
        group_id: "group-82",
        occurred_on: "2026-11-27",
        arrival_on: "2027-02-10",
        departure_on: "2027-02-13"
      }),
      credit_op(%{
        operation_id: "op-credit",
        group_id: "group-82",
        occurred_on: "2026-11-28",
        amount_cents: 11_000
      }),
      payment_op(%{
        operation_id: "op-pay-2",
        group_id: "group-82",
        occurred_on: "2026-11-29",
        amount_cents: 8500
      })
    ])

    :ok
  end

  defp cancel_82(overrides) do
    cancel_op(Map.merge(%{operation_id: "cancel-82", group_id: "group-82"}, overrides))
  end

  describe "a refundable cancellation of a group funded by cash and credit" do
    test "refunds the cash and returns the credit to its original lot", %{conn: conn} do
      assert %{
               "status" => "applied",
               "refunded_cents" => 8500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = submit_one(conn, cancel_82(%{occurred_on: @refundable_on}))

      assert %{
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-27"
                 }
               ]
             } = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 8500,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             } = read_ledger(conn, on: @refundable_on)
    end

    test "converts only the cash when hotel credit is chosen again", %{conn: conn} do
      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 9350
             } =
               submit_one(
                 conn,
                 cancel_82(%{occurred_on: @refundable_on, refund_method: "hotel_credit"})
               )

      # The restored 11_000 never receives a second bonus; only the 8500 of cash does.
      assert %{
               "available_cents" => 20_350,
               "lots" => [
                 %{"source_operation_id" => "cancel-17", "remaining_cents" => 11_000},
                 %{"source_operation_id" => "cancel-82", "remaining_cents" => 9350}
               ]
             } = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{
               "cash_converted_to_credit_cents" => 18_500,
               "credit_liability_cents" => 20_350
             } = read_ledger(conn, on: @refundable_on)
    end

    test "restoring credit does not change the liability", %{conn: conn} do
      before = read_ledger(conn, on: @refundable_on)["credit_liability_cents"]

      submit_one(conn, cancel_82(%{occurred_on: @refundable_on}))

      assert read_ledger(conn, on: @refundable_on)["credit_liability_cents"] == before
    end
  end

  describe "a non-refundable cancellation of a group funded by cash and credit" do
    test "retains the cash and consumes the credit", %{conn: conn} do
      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 8500,
               "credit_issued_cents" => 0
             } = submit_one(conn, cancel_82(%{occurred_on: @too_late_on}))

      assert %{"available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-22", on: @too_late_on)

      assert %{
               "cash_held_cents" => 0,
               "cash_retained_cents" => 8500,
               "credit_liability_cents" => 0
             } = read_ledger(conn, on: @too_late_on)
    end

    test "the group keeps its record of what funded it", %{conn: conn} do
      submit_one(conn, cancel_82(%{occurred_on: @too_late_on}))

      assert %{
               "status" => "cancelled",
               "deposit_paid_cents" => 19_500,
               "cash_paid_cents" => 8500,
               "credit_paid_cents" => 11_000,
               "outstanding_deposit_cents" => 0
             } = read_group(conn, "group-82")
    end
  end

  describe "restoring credit that came from several lots" do
    setup %{conn: conn} do
      # Two more lots for guest-22, expiring a day apart.
      for {group_id, source_operation_id, cash, cancelled_on} <- [
            {"group-a", "cancel-40", 2000, "2026-11-28"},
            {"group-b", "cancel-41", 3000, "2026-11-29"}
          ] do
        submit(conn, [
          open_group_op(%{
            operation_id: "open-" <> group_id,
            group_id: group_id,
            occurred_on: "2026-11-27",
            arrival_on: "2027-03-10",
            departure_on: "2027-03-13"
          }),
          payment_op(%{
            operation_id: "pay-" <> group_id,
            group_id: group_id,
            amount_cents: cash
          }),
          cancel_op(%{
            operation_id: source_operation_id,
            group_id: group_id,
            occurred_on: cancelled_on,
            refund_method: "hotel_credit"
          })
        ])
      end

      # group-83 draws 4000 across both lots and then 500 more from the second.
      submit(conn, [
        open_group_op(%{
          operation_id: "open-group-83",
          group_id: "group-83",
          occurred_on: "2026-11-30",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        }),
        credit_op(%{
          operation_id: "op-credit-a",
          group_id: "group-83",
          occurred_on: "2026-12-01",
          amount_cents: 4000
        }),
        credit_op(%{
          operation_id: "op-credit-b",
          group_id: "group-83",
          occurred_on: "2026-12-01",
          amount_cents: 500
        })
      ])

      :ok
    end

    test "spends the earlier lot first and leaves the rest of the later one", %{conn: conn} do
      assert %{"credit_paid_cents" => 4500, "cash_paid_cents" => 0} = read_group(conn, "group-83")

      assert %{
               "available_cents" => 1000,
               "lots" => [%{"source_operation_id" => "cancel-41", "remaining_cents" => 1000}]
             } = read_credit(conn, "guest-22", on: "2026-12-01")
    end

    test "returns each amount to the lot and expiry it came from", %{conn: conn} do
      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } =
               submit_one(
                 conn,
                 cancel_op(%{
                   operation_id: "cancel-83",
                   group_id: "group-83",
                   occurred_on: @refundable_on
                 })
               )

      assert %{
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-40",
                   "remaining_cents" => 2200,
                   "expires_on" => "2027-11-29"
                 },
                 %{
                   "source_operation_id" => "cancel-41",
                   "remaining_cents" => 3300,
                   "expires_on" => "2027-11-30"
                 }
               ]
             } = read_credit(conn, "guest-22", on: @refundable_on)
    end
  end

  describe "restoring credit whose lot has already expired" do
    test "the amount expires immediately and leaves the liability", %{conn: conn} do
      # Move the stay so the group is still refundable after the lot's expiry.
      submit(conn, [
        reschedule_op(%{
          operation_id: "op-move",
          group_id: "group-82",
          occurred_on: "2026-11-30",
          new_arrival_on: "2028-02-10"
        })
      ])

      # 2027-11-28 is past the lot's 2027-11-27 expiry but well inside the window.
      assert %{"status" => "applied", "refunded_cents" => 8500} =
               submit_one(conn, cancel_82(%{occurred_on: "2027-11-28"}))

      assert %{"available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-22", on: "2027-11-28")

      assert %{"credit_liability_cents" => 0} = read_ledger(conn, on: "2027-11-28")
    end
  end
end
