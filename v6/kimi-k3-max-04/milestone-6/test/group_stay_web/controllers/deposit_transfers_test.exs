defmodule GroupStayWeb.DepositTransfersTest do
  @moduledoc """
  `transfer_deposit` and its ripple effects across statements, reductions,
  and chargebacks (docs/requests/05-deposit-transfers.md).

  Scenario groups use a single room at rate 3000 for one night, so the
  deposit due is 600 per group.
  """
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: [operation]})
    |> json_response(200)
    |> get_in(["results"])
    |> hd()
  end

  defp applied!(result) do
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group_view(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment_view(conn, payment_operation_id) do
    conn
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp next_id, do: "op-#{System.unique_integer([:positive])}"

  # One room, one night, rate 3000: lodging 3000, due 600.
  defp open_op(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 3000}]
      },
      overrides
    )
  end

  defp pay_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp credit_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp transfer_op(source_id, destination_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "transfer_deposit",
        "source_group_id" => source_id,
        "destination_group_id" => destination_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reduce_op(payment_operation_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "reduce_cash_payment",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  # Issues `amount` of credit to `guest_id` by cancelling a throwaway group.
  defp credit_lot_ops(guest_id, amount) do
    lot_group = "lot-#{System.unique_integer([:positive])}"

    ops = [
      open_op(lot_group, guest_id),
      pay_op(lot_group, amount),
      cancel_op(lot_group, %{"refund_method" => "hotel_credit"})
    ]

    ops
  end

  describe "validation" do
    test "source existence resolves first, then destination", %{conn: conn} do
      source_id = "src-a"
      destination_id = "dst-a"

      rejected = submit_one(conn, transfer_op(source_id, destination_id, 10))

      assert %{"status" => "rejected", "code" => "group_not_found", "group_id" => ^source_id} =
               rejected

      applied!(submit_one(conn, open_op(source_id, "guest-22")))

      rejected2 = submit_one(conn, transfer_op(source_id, destination_id, 10))

      assert %{"status" => "rejected", "code" => "group_not_found", "group_id" => ^destination_id} =
               rejected2
    end

    test "same group or different guests reject as invalid_transfer", %{conn: conn} do
      open = applied!(submit_one(conn, open_op("group-same", "guest-22")))

      rejected = submit_one(conn, transfer_op(open["group_id"], open["group_id"], 10))
      assert %{"status" => "rejected", "code" => "invalid_transfer"} = rejected

      foreign = applied!(submit_one(conn, open_op("group-foreign", "guest-99")))

      rejected2 = submit_one(conn, transfer_op(open["group_id"], foreign["group_id"], 10))
      assert %{"status" => "rejected", "code" => "invalid_transfer"} = rejected2
    end

    test "a cancelled source or destination rejects with group_not_active", %{conn: conn} do
      open = applied!(submit_one(conn, open_op("group-ncx", "guest-22")))
      applied!(submit_one(conn, cancel_op(open["group_id"])))
      active = applied!(submit_one(conn, open_op("group-nct", "guest-22")))

      rejected = submit_one(conn, transfer_op(open["group_id"], active["group_id"], 10))

      assert %{"status" => "rejected", "code" => "group_not_active", "group_id" => gid} =
               rejected

      assert gid == open["group_id"]

      rejected2 = submit_one(conn, transfer_op(active["group_id"], open["group_id"], 10))

      assert %{"status" => "rejected", "code" => "group_not_active", "group_id" => gid2} =
               rejected2

      assert gid2 == open["group_id"]
    end

    test "source revision checked, then destination revision, before transfer rules", %{
      conn: conn
    } do
      open_src = applied!(submit_one(conn, open_op("group-src-rev", "guest-22")))
      open_dst = applied!(submit_one(conn, open_op("group-dst-rev", "guest-22")))

      rejected =
        submit_one(
          conn,
          transfer_op(open_src["group_id"], open_dst["group_id"], 10, %{"expected_revision" => 2})
        )

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => src_gid,
               "expected_revision" => 2,
               "actual_revision" => 1
             } = rejected

      assert src_gid == open_src["group_id"]

      rejected2 =
        submit_one(
          conn,
          transfer_op(open_src["group_id"], open_dst["group_id"], 10, %{
            "destination_expected_revision" => 2
          })
        )

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => dst_gid,
               "expected_revision" => 2,
               "actual_revision" => 1
             } = rejected2

      assert dst_gid == open_dst["group_id"]

      applied!(submit_one(conn, pay_op(open_src["group_id"], 400)))

      done =
        submit_one(
          conn,
          transfer_op(open_src["group_id"], open_dst["group_id"], 100, %{
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        )

      assert %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2} = done
    end

    test "rejects non-positive amounts, excess held funding, and excess outstanding", %{
      conn: conn
    } do
      open_src = applied!(submit_one(conn, open_op("group-src-amt", "guest-22")))
      open_dst = applied!(submit_one(conn, open_op("group-dst-amt", "guest-22")))

      for bad <- [0, -50] do
        rejected =
          submit_one(conn, transfer_op(open_src["group_id"], open_dst["group_id"], bad))

        assert %{"status" => "rejected", "code" => "invalid_amount"} = rejected
      end

      applied!(submit_one(conn, pay_op(open_src["group_id"], 400)))

      held = submit_one(conn, transfer_op(open_src["group_id"], open_dst["group_id"], 401))
      assert %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} = held

      applied!(submit_one(conn, pay_op(open_dst["group_id"], 201)))

      out = submit_one(conn, transfer_op(open_src["group_id"], open_dst["group_id"], 400))
      assert %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"} = out
    end

    test "rejected transfers increment nothing", %{conn: conn} do
      open_src = applied!(submit_one(conn, open_op("group-src-norv", "guest-22")))
      open_dst = applied!(submit_one(conn, open_op("group-dst-norv", "guest-22")))

      rejected = submit_one(conn, transfer_op(open_src["group_id"], open_dst["group_id"], 0))
      assert rejected["status"] == "rejected"

      assert %{"revision" => 1} = group_view(conn, open_src["group_id"])
      assert %{"revision" => 1} = group_view(conn, open_dst["group_id"])
    end
  end

  describe "application" do
    test "moves held funding, bumps both revisions, and changes no ledger total", %{conn: conn} do
      source_id = "mv-src"
      destination_id = "mv-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      applied!(submit_one(conn, pay_op(source_id, 400)))

      done = applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      assert %{
               "source_group_id" => ^source_id,
               "destination_group_id" => ^destination_id,
               "amount_cents" => 250,
               "source_outstanding_deposit_cents" => 450,
               "destination_outstanding_deposit_cents" => 350,
               "source_revision" => 3,
               "destination_revision" => 2
             } = done

      assert %{"cash_paid_cents" => 150, "revision" => 3} = group_view(conn, source_id)
      assert %{"cash_paid_cents" => 250, "revision" => 2} = group_view(conn, destination_id)
      assert %{"cash_held_cents" => 400} = ledger(conn)
    end

    test "draws the most recently created allocation first across funding kinds", %{conn: conn} do
      source_id = "newest-src"
      destination_id = "newest-dst"

      batch =
        [open_op(source_id, "guest-22"), open_op(destination_id, "guest-22")] ++
          credit_lot_ops("guest-22", 200) ++
          [pay_op(source_id, 200), credit_op(source_id, 200)]

      Enum.each(submit(conn, batch), &applied!/1)

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 50)))

      # The newest allocation is the credit application; only it drained.
      assert %{"cash_paid_cents" => 200, "credit_paid_cents" => 150} =
               group_view(conn, source_id)

      assert %{"cash_paid_cents" => 0, "credit_paid_cents" => 50} =
               group_view(conn, destination_id)
    end

    test "splits an allocation row; the statement adds held_by_group ordered by group id", %{
      conn: conn
    } do
      source_id = "group-1-src"
      destination_id = "group-2-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      pay = applied!(submit_one(conn, pay_op(source_id, 400)))

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      payment = payment_view(conn, pay["operation_id"])

      assert %{
               "held_cents" => 400,
               "held_by_group" => [
                 %{"group_id" => ^source_id, "amount_cents" => 150},
                 %{"group_id" => ^destination_id, "amount_cents" => 250}
               ]
             } = payment
    end

    test "a retry returns the exact stored result without moving funding again", %{conn: conn} do
      source_id = "idem-src"
      destination_id = "idem-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      applied!(submit_one(conn, pay_op(source_id, 400)))

      op = transfer_op(source_id, destination_id, 250)
      done = applied!(submit_one(conn, op))

      assert %{"source_revision" => 3, "destination_revision" => 2} = done

      replayed = submit_one(conn, op)
      assert replayed == done

      assert %{"cash_paid_cents" => 150} = group_view(conn, source_id)
      assert %{"cash_paid_cents" => 250} = group_view(conn, destination_id)
    end

    test "payments untouched by a transfer keep the original statement shape", %{conn: conn} do
      pay = applied!(submit_one(conn, open_op("shape-src", "guest-22")))
      pay2 = applied!(submit_one(conn, pay_op(pay["group_id"], 400)))

      payment = payment_view(conn, pay2["operation_id"])

      assert %{"held_cents" => 400} = payment
      refute Map.has_key?(payment, "held_by_group")
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination policy with its bonus", %{conn: conn} do
      source_id = "settle-src"
      destination_id = "settle-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      by_cash = applied!(submit_one(conn, pay_op(source_id, 400)))

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      settled =
        applied!(
          submit_one(conn, cancel_op(destination_id, %{"refund_method" => "hotel_credit"}))
        )

      assert %{"credit_issued_cents" => 275} = settled

      assert %{"available_cents" => 275} = guest_credit(conn, "guest-22")

      payment = payment_view(conn, by_cash["operation_id"])

      assert %{
               "held_cents" => 150,
               "held_by_group" => [%{"group_id" => ^source_id, "amount_cents" => 150}]
             } = payment
    end

    test "transferred credit returns to its original lot on a refundable settlement", %{
      conn: conn
    } do
      source_id = "credit-src"
      destination_id = "credit-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))

      [open_lot, pay_lot, settled_lot, applied] =
        submit(conn, credit_lot_ops("guest-22", 200) ++ [credit_op(source_id, 200)])
        |> Enum.map(& &1)

      Enum.each([open_lot, pay_lot, settled_lot, applied], &applied!/1)

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 150)))

      settled = applied!(submit_one(conn, cancel_op(destination_id)))
      assert %{"credit_issued_cents" => 0} = settled

      # 20 of the original 220 was available, the returned 150 became
      # available again, and the 50 still held on the source is liability too.
      assert %{"available_cents" => 170, "lots" => [lot]} = guest_credit(conn, "guest-22")
      assert lot["source_operation_id"] == settled_lot["operation_id"]
      assert %{"credit_liability_cents" => 220} = ledger(conn)
    end

    test "a reduction follows allocations across groups and bumps every touched group", %{
      conn: conn
    } do
      source_id = "red-src"
      destination_id = "red-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      pay = applied!(submit_one(conn, pay_op(source_id, 400)))

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      done =
        applied!(
          submit_one(conn, reduce_op(pay["operation_id"], 250, %{"expected_revision" => 3}))
        )

      assert %{
               "group_id" => ^source_id,
               "amount_cents" => 250,
               "outstanding_deposit_cents" => 450,
               "revision" => 4
             } = done

      # The newest allocation sat on the destination, so it drained first.
      assert %{"revision" => 3, "outstanding_deposit_cents" => 600} =
               group_view(conn, destination_id)
    end

    test "a chargeback follows allocations across groups too", %{conn: conn} do
      source_id = "cb-src"
      destination_id = "cb-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      pay = applied!(submit_one(conn, pay_op(source_id, 400)))

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      done =
        applied!(
          submit_one(conn, %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => pay["operation_id"]
          })
        )

      assert %{
               "group_id" => ^source_id,
               "charged_back_cents" => 400,
               "outstanding_deposit_cents" => 600,
               "revision" => 4
             } = done

      assert %{"revision" => 3, "outstanding_deposit_cents" => 600} =
               group_view(conn, destination_id)

      assert %{"cash_charged_back_cents" => 400, "cash_held_cents" => 0} = ledger(conn)
    end

    test "after everything settles, held_by_group returns an empty list", %{conn: conn} do
      source_id = "empty-src"
      destination_id = "empty-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      pay = applied!(submit_one(conn, pay_op(source_id, 400)))

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      for group_id <- [source_id, destination_id] do
        applied!(submit_one(conn, cancel_op(group_id)))
      end

      payment = payment_view(conn, pay["operation_id"])

      assert %{"held_cents" => 0, "held_by_group" => []} = payment
    end

    test "a chargeback follows allocations that settled at the destination too", %{conn: conn} do
      source_id = "cbx-src"
      destination_id = "cbx-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      pay = applied!(submit_one(conn, pay_op(source_id, 400)))

      applied!(submit_one(conn, transfer_op(source_id, destination_id, 250)))

      # Settle the transferred 250 into credit at the destination (a 275 lot).
      settled =
        applied!(
          submit_one(conn, cancel_op(destination_id, %{"refund_method" => "hotel_credit"}))
        )

      assert %{"credit_issued_cents" => 275} = settled

      charge_back =
        applied!(
          submit_one(conn, %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => pay["operation_id"]
          })
        )

      assert %{
               "group_id" => ^source_id,
               "charged_back_cents" => 400,
               "outstanding_deposit_cents" => 600,
               "revision" => 4
             } = charge_back

      # The issued lot's entitlement is fully revoked; no shortfall remains.
      assert %{"available_cents" => 0, "lots" => []} = guest_credit(conn, "guest-22")

      assert %{
               "cash_charged_back_cents" => 400,
               "cash_converted_to_credit_cents" => 0,
               "cash_held_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = ledger(conn)
    end

    test "a later operation in the same batch sees the transfer", %{conn: conn} do
      source_id = "batch-src"
      destination_id = "batch-dst"

      applied!(submit_one(conn, open_op(source_id, "guest-22")))
      applied!(submit_one(conn, open_op(destination_id, "guest-22")))
      pay = applied!(submit_one(conn, pay_op(source_id, 400)))

      [transferred, reduced] =
        submit(conn, [
          transfer_op(source_id, destination_id, 250),
          reduce_op(pay["operation_id"], 250, %{"expected_revision" => 3})
        ])

      assert %{"status" => "applied"} = transferred
      assert %{"status" => "applied", "revision" => 4} = reduced
    end
  end
end
