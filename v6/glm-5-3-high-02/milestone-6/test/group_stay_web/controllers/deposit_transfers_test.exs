defmodule GroupStayWeb.DepositTransfersTest do
  @moduledoc """
  Product request 05: deposit transfers between two active groups of the
  same guest.

  A transfer moves held funding — cash and hotel credit allocated to active
  rooms — from the source's allocations in reverse allocation order into
  the destination's rooms in their original order, preserving the draw
  order and each unit's provenance. Nothing is settled or revalued, and
  both groups' revisions move. Later settlements, reductions, and
  chargebacks follow the funding wherever it currently sits, and a payment
  that has participated in a transfer reports which groups hold its cash.
  """

  use GroupStayWeb.ConnCase, async: true

  @guest "guest-22"
  @booked_on "2026-10-03"
  @arrival_on "2027-03-10"
  @departure_on "2027-03-13"
  # Two rooms, three nights at 10000: lodging 60000, flexible deposit 6000 each.

  defp open_operation(group_id, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, @guest),
      "property_id" => Keyword.get(opts, :property_id, "ams-canal"),
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
        ])
    }
  end

  defp payment_operation(group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-pay-#{group_id}-#{amount_cents}"),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id
    }
    |> maybe_put("refund_method", Keyword.get(opts, :refund_method))
  end

  defp cancel_rooms_operation(group_id, room_ids, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-cancel-rooms-#{group_id}"),
      "type" => "cancel_rooms",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "room_ids" => room_ids
    }
    |> maybe_put("refund_method", Keyword.get(opts, :refund_method))
  end

  defp reduce_operation(payment_operation_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-reduce-#{payment_operation_id}"),
      "type" => "reduce_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_operation(payment_operation_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-charge-#{payment_operation_id}"),
      "type" => "charge_back_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id
    }
  end

  defp credit_operation(group_id, amount_cents, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-credit-#{group_id}-#{amount_cents}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_operation(source_group_id, destination_group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" =>
        Keyword.get(
          opts,
          :operation_id,
          "op-transfer-#{source_group_id}-#{destination_group_id}-#{amount_cents}"
        ),
      "type" => "transfer_deposit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put("expected_revision", Keyword.get(opts, :expected_revision))
    |> maybe_put(
      "destination_expected_revision",
      Keyword.get(opts, :destination_expected_revision)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp apply_op!(conn, operation) do
    [result] = submit!(conn, [operation])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp open_group!(conn, group_id, opts \\ []) do
    apply_op!(conn, open_operation(group_id, opts))
  end

  defp group_data(group_id) do
    conn = get(build_conn(), "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp room_data(group_id, room_id) do
    Enum.find(group_data(group_id)["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(on \\ nil) do
    conn = get(build_conn(), "/api/v1/ledger" <> on_query(on))
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp guest_credit(guest_id, on) do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> on_query(on))
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp payment_statement(payment_operation_id) do
    conn = get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
    {conn.status, conn.status == 200 && json_response(conn, 200)["data"]}
  end

  defp on_query(nil), do: ""
  defp on_query(on), do: "?on=#{on}"

  # Funds the guest with a credit lot by cancelling a paid group in credit.
  defp issue_lot!(conn, group_id, cash_cents, cancelled_on) do
    open_group!(conn, group_id)
    apply_op!(conn, payment_operation(group_id, cash_cents, occurred_on: "2026-10-05"))

    apply_op!(
      conn,
      cancel_operation(group_id, occurred_on: cancelled_on, refund_method: "hotel_credit")
    )
  end

  describe "moving held funding" do
    test "moves held funding between two active groups of the same guest" do
      conn = build_conn()
      open_group!(conn, "g-tr-src")
      apply_op!(conn, payment_operation("g-tr-src", 8000, operation_id: "op-tr-pay"))
      open_group!(conn, "g-tr-dst")

      result =
        apply_op!(conn, transfer_operation("g-tr-src", "g-tr-dst", 3000, operation_id: "op-tr-1"))

      assert result == %{
               "operation_id" => "op-tr-1",
               "status" => "applied",
               "source_group_id" => "g-tr-src",
               "destination_group_id" => "g-tr-dst",
               "amount_cents" => 3000,
               "source_outstanding_deposit_cents" => 7000,
               "destination_outstanding_deposit_cents" => 9000,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = group_data("g-tr-src")
      assert source["cash_paid_cents"] == 5000
      assert source["outstanding_deposit_cents"] == 7000
      assert source["revision"] == 3
      assert room_data("g-tr-src", "room-a")["cash_paid_cents"] == 5000
      assert room_data("g-tr-src", "room-b")["cash_paid_cents"] == 0

      destination = group_data("g-tr-dst")
      assert destination["cash_paid_cents"] == 3000
      assert destination["outstanding_deposit_cents"] == 9000
      assert destination["revision"] == 2
      assert room_data("g-tr-dst", "room-a")["cash_paid_cents"] == 3000

      # No ledger total moved: the same cash is held, just elsewhere.
      assert ledger() == %{
               "cash_held_cents" => 8000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "draws from the source in reverse order and fills in draw order" do
      conn = build_conn()
      open_group!(conn, "g-draw-src")
      # pay-1 fills room-a with 4000; pay-2 finishes room-a and starts room-b.
      apply_op!(conn, payment_operation("g-draw-src", 4000, operation_id: "op-draw-pay-1"))
      apply_op!(conn, payment_operation("g-draw-src", 4000, operation_id: "op-draw-pay-2"))
      open_group!(conn, "g-draw-dst")

      result =
        apply_op!(
          conn,
          transfer_operation("g-draw-src", "g-draw-dst", 8000, operation_id: "op-draw-tr")
        )

      assert result["source_outstanding_deposit_cents"] == 12_000
      assert result["destination_outstanding_deposit_cents"] == 4000
      assert result["source_revision"] == 4
      assert result["destination_revision"] == 2

      assert group_data("g-draw-src")["cash_paid_cents"] == 0
      assert room_data("g-draw-dst", "room-a")["cash_paid_cents"] == 6000
      assert room_data("g-draw-dst", "room-b")["cash_paid_cents"] == 2000

      # The draw order is preserved at the destination: pay-2's cash (drawn
      # first) funds room-a ahead of pay-1's, so pay-1's oldest slice there
      # is room-b's, which a reduction removes first.
      reduction =
        apply_op!(conn, reduce_operation("op-draw-pay-1", 2000, operation_id: "op-draw-reduce"))

      assert reduction["revision"] == 5
      assert room_data("g-draw-dst", "room-a")["cash_paid_cents"] == 6000
      assert room_data("g-draw-dst", "room-b")["cash_paid_cents"] == 0
      assert group_data("g-draw-dst")["outstanding_deposit_cents"] == 6000
    end

    test "moves cash and credit together, keeping each unit's provenance" do
      conn = build_conn()
      issue_lot!(conn, "g-mix-lot-src", 2000, "2027-01-05")

      open_group!(conn, "g-mix-src", occurred_on: "2027-01-10")

      apply_op!(
        conn,
        payment_operation("g-mix-src", 4000,
          occurred_on: "2027-01-11",
          operation_id: "op-mix-pay"
        )
      )

      apply_op!(conn, credit_operation("g-mix-src", 2200, occurred_on: "2027-01-12"))
      open_group!(conn, "g-mix-dst", occurred_on: "2027-01-10")

      before = ledger("2027-01-13")
      assert before["cash_held_cents"] == 4000
      assert before["cash_converted_to_credit_cents"] == 2000
      assert before["credit_liability_cents"] == 2200

      apply_op!(
        conn,
        transfer_operation("g-mix-src", "g-mix-dst", 6200,
          occurred_on: "2027-01-13",
          operation_id: "op-mix-tr"
        )
      )

      # The source keeps nothing; the destination holds both kinds.
      assert group_data("g-mix-src")["deposit_paid_cents"] == 0
      assert room_data("g-mix-dst", "room-a")["cash_paid_cents"] == 3800
      assert room_data("g-mix-dst", "room-a")["credit_paid_cents"] == 2200
      assert room_data("g-mix-dst", "room-b")["cash_paid_cents"] == 200
      assert group_data("g-mix-dst")["outstanding_deposit_cents"] == 5800

      # Nothing settled, revalued, resumed, or expired.
      assert ledger("2027-01-13") == before
      assert guest_credit(@guest, "2027-01-13")["available_cents"] == 0

      # The payment's cash is now held by the destination group.
      {200, statement} = payment_statement("op-mix-pay")
      assert statement["held_by_group"] == [%{"group_id" => "g-mix-dst", "amount_cents" => 4000}]
    end

    test "moves only held funding; settled history stays with its group" do
      conn = build_conn()
      open_group!(conn, "g-hist-src")
      apply_op!(conn, payment_operation("g-hist-src", 8000, operation_id: "op-hist-pay"))
      open_group!(conn, "g-hist-dst")

      # room-b's 2000 is refunded; room-a's 6000 stays held.
      apply_op!(
        conn,
        cancel_rooms_operation("g-hist-src", ["room-b"], occurred_on: "2027-01-05")
      )

      [rejected] =
        submit!(conn, [
          transfer_operation("g-hist-src", "g-hist-dst", 6001, operation_id: "op-hist-tr-1")
        ])

      assert rejected["code"] == "transfer_exceeds_held_funding"

      apply_op!(
        conn,
        transfer_operation("g-hist-src", "g-hist-dst", 6000, operation_id: "op-hist-tr-2")
      )

      assert group_data("g-hist-src")["cash_paid_cents"] == 0
      assert group_data("g-hist-src")["outstanding_deposit_cents"] == 6000
      assert group_data("g-hist-dst")["cash_paid_cents"] == 6000

      # The refund is untouched history of the source group.
      assert ledger("2027-01-06")["cash_refunded_cents"] == 2000
      assert ledger("2027-01-06")["cash_held_cents"] == 6000
    end
  end

  describe "rejections" do
    test "rejects with the documented codes" do
      conn = build_conn()
      open_group!(conn, "g-rej-src")
      apply_op!(conn, payment_operation("g-rej-src", 5000, operation_id: "op-rej-pay"))
      open_group!(conn, "g-rej-dst")
      open_group!(conn, "g-rej-other-guest", guest_id: "guest-99")
      open_group!(conn, "g-rej-full")
      apply_op!(conn, payment_operation("g-rej-full", 12_000, operation_id: "op-rej-full-pay"))
      open_group!(conn, "g-rej-cancelled")
      apply_op!(conn, cancel_operation("g-rej-cancelled", occurred_on: "2027-01-05"))

      # The groups are the same.
      [result] =
        submit!(conn, [transfer_operation("g-rej-src", "g-rej-src", 100, operation_id: "op-r-1")])

      assert result["code"] == "invalid_transfer"

      # The groups belong to different guests.
      [result] =
        submit!(conn, [
          transfer_operation("g-rej-src", "g-rej-other-guest", 100, operation_id: "op-r-2")
        ])

      assert result["code"] == "invalid_transfer"

      # Source existence resolves first, then destination existence.
      [result] =
        submit!(conn, [transfer_operation("g-rej-none", "g-rej-dst", 100, operation_id: "op-r-3")])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "g-rej-none"

      [result] =
        submit!(conn, [transfer_operation("g-rej-src", "g-rej-none", 100, operation_id: "op-r-4")])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "g-rej-none"

      # Either group not active, with that group named.
      [result] =
        submit!(conn, [
          transfer_operation("g-rej-cancelled", "g-rej-dst", 100, operation_id: "op-r-5")
        ])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "g-rej-cancelled"

      [result] =
        submit!(conn, [
          transfer_operation("g-rej-src", "g-rej-cancelled", 100, operation_id: "op-r-6")
        ])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "g-rej-cancelled"

      # Non-positive or unusable amounts.
      for {amount, index} <- Enum.with_index([0, -100, "500"]) do
        [result] =
          submit!(conn, [
            transfer_operation("g-rej-src", "g-rej-dst", amount,
              operation_id: "op-r-amount-#{index}"
            )
          ])

        assert result["code"] == "invalid_amount"
      end

      # More than the source's held funding.
      [result] =
        submit!(conn, [transfer_operation("g-rej-src", "g-rej-dst", 5001, operation_id: "op-r-7")])

      assert result["code"] == "transfer_exceeds_held_funding"

      # More than the destination's outstanding deposit, though the source
      # holds enough.
      [result] =
        submit!(conn, [
          transfer_operation("g-rej-src", "g-rej-full", 5000, operation_id: "op-r-8")
        ])

      assert result["code"] == "transfer_exceeds_outstanding"

      # The held-funding bound is checked first.
      [result] =
        submit!(conn, [
          transfer_operation("g-rej-src", "g-rej-full", 9000, operation_id: "op-r-9")
        ])

      assert result["code"] == "transfer_exceeds_held_funding"

      # A structurally unusable operation cannot identify its groups.
      [result] =
        submit!(conn, [
          %{
            "operation_id" => "op-r-10",
            "type" => "transfer_deposit",
            "occurred_on" => @booked_on,
            "source_group_id" => "g-rej-src",
            "amount_cents" => 100
          }
        ])

      assert result["code"] == "invalid_operation"

      # Nothing moved and no revision moved.
      assert group_data("g-rej-src")["cash_paid_cents"] == 5000
      assert group_data("g-rej-src")["revision"] == 2
      assert group_data("g-rej-dst")["revision"] == 1
    end

    test "checks both revisions before the transfer rules, source first" do
      conn = build_conn()
      open_group!(conn, "g-rev-src")
      open_group!(conn, "g-rev-dst")
      open_group!(conn, "g-rev-other", guest_id: "guest-99")
      apply_op!(conn, cancel_operation("g-rev-other", occurred_on: "2027-01-05"))
      open_group!(conn, "g-rev-cancelled")
      apply_op!(conn, cancel_operation("g-rev-cancelled", occurred_on: "2027-01-05"))

      # A stale source revision is rejected before the transfer rules; the
      # destination revision has not been checked yet.
      [result] =
        submit!(conn, [
          transfer_operation("g-rev-src", "g-rev-dst", 100,
            operation_id: "op-rev-1",
            expected_revision: 7,
            destination_expected_revision: 9
          )
        ])

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "g-rev-src"
      assert result["expected_revision"] == 7
      assert result["actual_revision"] == 1

      # A stale destination revision names the destination group.
      [result] =
        submit!(conn, [
          transfer_operation("g-rev-src", "g-rev-dst", 100,
            operation_id: "op-rev-2",
            expected_revision: 1,
            destination_expected_revision: 9
          )
        ])

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "g-rev-dst"
      assert result["expected_revision"] == 9
      assert result["actual_revision"] == 1

      # Revisions precede the invalid-transfer rule, even for one group.
      [result] =
        submit!(conn, [
          transfer_operation("g-rev-src", "g-rev-src", 100,
            operation_id: "op-rev-3",
            destination_expected_revision: 4
          )
        ])

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "g-rev-src"

      # The invalid-transfer rule precedes activity and amount checks.
      [result] =
        submit!(conn, [
          transfer_operation("g-rev-src", "g-rev-other", 0, operation_id: "op-rev-4")
        ])

      assert result["code"] == "invalid_transfer"

      # Activity precedes the amount check.
      [result] =
        submit!(conn, [
          transfer_operation("g-rev-cancelled", "g-rev-dst", 0, operation_id: "op-rev-5")
        ])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "g-rev-cancelled"

      # Unusable revision guards are structurally invalid.
      for {key, index} <- Enum.with_index([:expected_revision, :destination_expected_revision]) do
        [result] =
          submit!(conn, [
            transfer_operation("g-rev-src", "g-rev-dst", 100,
              operation_id: "op-rev-guard-#{index}"
            )
            |> Map.put(key |> Atom.to_string(), "1")
          ])

        assert result["code"] == "invalid_operation"
      end
    end

    test "applies with both revision guards in place" do
      conn = build_conn()
      open_group!(conn, "g-guard-src")
      apply_op!(conn, payment_operation("g-guard-src", 5000, operation_id: "op-guard-pay"))
      open_group!(conn, "g-guard-dst")

      result =
        apply_op!(
          conn,
          transfer_operation("g-guard-src", "g-guard-dst", 100,
            operation_id: "op-guard-tr",
            expected_revision: 2,
            destination_expected_revision: 1
          )
        )

      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2
      assert group_data("g-guard-src")["revision"] == 3
      assert group_data("g-guard-dst")["revision"] == 2
    end
  end

  describe "later corrections across groups" do
    test "a reduction follows a payment's allocations across groups" do
      conn = build_conn()
      open_group!(conn, "g-red-src")
      apply_op!(conn, payment_operation("g-red-src", 4000, operation_id: "op-red-pay"))
      open_group!(conn, "g-red-dst")

      apply_op!(
        conn,
        transfer_operation("g-red-src", "g-red-dst", 3000, operation_id: "op-red-tr")
      )

      # The payment now holds 1000 in its original group and 3000 in the
      # destination; the reduction removes the destination's cash first.
      result =
        apply_op!(conn, reduce_operation("op-red-pay", 3500, operation_id: "op-red-reduce"))

      assert result == %{
               "operation_id" => "op-red-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-red-pay",
               "group_id" => "g-red-src",
               "amount_cents" => 3500,
               "outstanding_deposit_cents" => 11_500,
               "revision" => 4
             }

      # The addressed group's revision is the reported one; the
      # destination's revision moved too because its funding changed.
      assert group_data("g-red-src")["revision"] == 4
      assert group_data("g-red-dst")["revision"] == 3

      assert group_data("g-red-src")["cash_paid_cents"] == 500
      assert group_data("g-red-src")["outstanding_deposit_cents"] == 11_500
      assert group_data("g-red-dst")["cash_paid_cents"] == 0
      assert group_data("g-red-dst")["outstanding_deposit_cents"] == 12_000

      {200, statement} = payment_statement("op-red-pay")
      assert statement["held_by_group"] == [%{"group_id" => "g-red-src", "amount_cents" => 500}]
      assert statement["held_cents"] == 500
      assert statement["reduced_cents"] == 3500
    end

    test "a chargeback follows a payment's allocations across groups" do
      conn = build_conn()
      open_group!(conn, "g-cbt-src")
      apply_op!(conn, payment_operation("g-cbt-src", 6000, operation_id: "op-cbt-pay"))
      open_group!(conn, "g-cbt-dst")

      apply_op!(
        conn,
        transfer_operation("g-cbt-src", "g-cbt-dst", 4000, operation_id: "op-cbt-tr")
      )

      result = apply_op!(conn, charge_back_operation("op-cbt-pay", operation_id: "op-cbt-cb"))

      assert result == %{
               "operation_id" => "op-cbt-cb",
               "status" => "applied",
               "payment_operation_id" => "op-cbt-pay",
               "group_id" => "g-cbt-src",
               "charged_back_cents" => 6000,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 4
             }

      # Both groups' deposits reopened and both revisions moved once.
      assert group_data("g-cbt-src")["outstanding_deposit_cents"] == 12_000
      assert group_data("g-cbt-dst")["outstanding_deposit_cents"] == 12_000
      assert group_data("g-cbt-src")["revision"] == 4
      assert group_data("g-cbt-dst")["revision"] == 3

      assert ledger()["cash_charged_back_cents"] == 6000
      assert ledger()["cash_held_cents"] == 0

      # The statement keeps reporting the groups, now holding nothing.
      {200, statement} = payment_statement("op-cbt-pay")
      assert statement["held_by_group"] == []
      assert statement["held_cents"] == 0
      assert statement["charged_back_cents"] == 6000
    end
  end

  describe "later settlement of transferred funding" do
    test "transferred cash settles under the destination group's policy" do
      conn = build_conn()
      # The source is flexible and inside its refundable window; the
      # destination is advance purchase, which never refunds.
      open_group!(conn, "g-settle-src")
      apply_op!(conn, payment_operation("g-settle-src", 3000, operation_id: "op-settle-pay"))
      open_group!(conn, "g-settle-dst", rate_plan: "advance_purchase")

      apply_op!(
        conn,
        transfer_operation("g-settle-src", "g-settle-dst", 3000, operation_id: "op-settle-tr")
      )

      result = apply_op!(conn, cancel_operation("g-settle-dst", occurred_on: "2027-01-05"))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 3000
      assert ledger("2027-01-05")["cash_retained_cents"] == 3000
    end

    test "transferred cash converted to hotel credit earns the bonus there" do
      conn = build_conn()
      open_group!(conn, "g-conv-src")
      apply_op!(conn, payment_operation("g-conv-src", 2000, operation_id: "op-conv-pay"))
      open_group!(conn, "g-conv-dst")

      apply_op!(
        conn,
        transfer_operation("g-conv-src", "g-conv-dst", 2000, operation_id: "op-conv-tr")
      )

      result =
        apply_op!(
          conn,
          cancel_operation("g-conv-dst", occurred_on: "2027-01-05", refund_method: "hotel_credit")
        )

      assert result["credit_issued_cents"] == 2200
      assert guest_credit(@guest, "2027-01-06")["available_cents"] == 2200

      {200, statement} = payment_statement("op-conv-pay")
      assert statement["converted_to_credit_cents"] == 2000
      assert statement["held_by_group"] == []
    end

    test "transferred credit restores to its original lot and expiry" do
      conn = build_conn()
      issue_lot!(conn, "g-cred-lot-src", 2000, "2027-01-05")

      open_group!(conn, "g-cred-src", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cred-src", 2200, occurred_on: "2027-01-15"))

      open_group!(conn, "g-cred-dst", occurred_on: "2027-01-10")

      apply_op!(
        conn,
        transfer_operation("g-cred-src", "g-cred-dst", 2200,
          occurred_on: "2027-01-20",
          operation_id: "op-cred-tr"
        )
      )

      # Applied credit keeps funding active rooms: nothing available and
      # the lot's expiry stays paused.
      assert guest_credit(@guest, "2027-01-21")["available_cents"] == 0
      assert room_data("g-cred-dst", "room-a")["credit_paid_cents"] == 2200
      assert room_data("g-cred-src", "room-a")["credit_paid_cents"] == 0
      assert ledger("2027-01-21")["credit_liability_cents"] == 2200

      # Refundable settlement restores it to the original lot, whole, with
      # the original expiry and no second bonus.
      apply_op!(conn, cancel_operation("g-cred-dst", occurred_on: "2027-02-01"))

      assert guest_credit(@guest, "2027-02-02") == %{
               "guest_id" => @guest,
               "available_cents" => 2200,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-cred-lot-src",
                   "remaining_cents" => 2200,
                   "expires_on" => "2028-01-06"
                 }
               ]
             }

      assert ledger("2027-02-02")["credit_liability_cents"] == 2200

      # The original expiry still governs, not the transfer date.
      assert guest_credit(@guest, "2028-01-07")["available_cents"] == 0
    end

    test "non-refundable settlement consumes transferred credit" do
      conn = build_conn()
      issue_lot!(conn, "g-cred-cons-src", 2000, "2027-01-05")

      open_group!(conn, "g-cred-cons-a", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cred-cons-a", 2200, occurred_on: "2027-01-15"))

      open_group!(conn, "g-cred-cons-b", occurred_on: "2027-01-10")

      apply_op!(
        conn,
        transfer_operation("g-cred-cons-a", "g-cred-cons-b", 2200,
          occurred_on: "2027-01-20",
          operation_id: "op-cred-cons-tr"
        )
      )

      apply_op!(conn, cancel_operation("g-cred-cons-b", occurred_on: "2027-03-01"))

      assert guest_credit(@guest, "2027-03-02")["available_cents"] == 0
      assert ledger("2027-03-02")["credit_liability_cents"] == 0
    end

    test "transferred credit returning to a shortfalled lot is absorbed" do
      conn = build_conn()
      open_group!(conn, "g-sh-src")
      apply_op!(conn, payment_operation("g-sh-src", 3000, operation_id: "op-sh-pay"))

      apply_op!(
        conn,
        cancel_operation("g-sh-src", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      # The lot (3300) is applied to one group and then transferred to
      # another, so it still funds an active group when its payment is
      # charged back.
      open_group!(conn, "g-sh-a", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-sh-a", 3300, occurred_on: "2027-01-15"))

      open_group!(conn, "g-sh-b", occurred_on: "2027-01-10")

      apply_op!(
        conn,
        transfer_operation("g-sh-a", "g-sh-b", 3300,
          occurred_on: "2027-01-20",
          operation_id: "op-sh-tr"
        )
      )

      # The chargeback does not change the group funded by the credit.
      revision_before = group_data("g-sh-b")["revision"]

      apply_op!(conn, charge_back_operation("op-sh-pay", operation_id: "op-sh-cb"))

      assert group_data("g-sh-b")["revision"] == revision_before
      assert ledger("2027-01-21")["credit_shortfall_cents"] == 3300
      assert ledger("2027-01-21")["credit_liability_cents"] == 3300

      # Returning to its shortfalled lot, the transferred credit is
      # absorbed by the clawback before anything becomes available.
      apply_op!(conn, cancel_operation("g-sh-b", occurred_on: "2027-02-01"))

      assert guest_credit(@guest, "2027-02-02")["available_cents"] == 0
      assert ledger("2027-02-02")["credit_shortfall_cents"] == 0
      assert ledger("2027-02-02")["credit_liability_cents"] == 0
    end
  end

  describe "payment statement evolution" do
    test "a transferred payment reports the groups holding its cash" do
      conn = build_conn()
      open_group!(conn, "g-st-src")
      apply_op!(conn, payment_operation("g-st-src", 4000, operation_id: "op-st-pay-1"))
      apply_op!(conn, payment_operation("g-st-src", 4000, operation_id: "op-st-pay-2"))
      open_group!(conn, "g-st-dst")

      apply_op!(conn, transfer_operation("g-st-src", "g-st-dst", 3000, operation_id: "op-st-tr"))

      # pay-2 is the newest funding, so the transfer draws from it first:
      # 3000 of its 4000 moved. The list is ordered by group_id.
      {200, statement} = payment_statement("op-st-pay-2")

      assert statement["held_by_group"] == [
               %{"group_id" => "g-st-dst", "amount_cents" => 3000},
               %{"group_id" => "g-st-src", "amount_cents" => 1000}
             ]

      assert statement["held_cents"] == 4000
      assert statement["held_by_group"] |> Enum.map(& &1["amount_cents"]) |> Enum.sum() == 4000

      # A payment that never participated keeps the earlier shape.
      {200, untouched} = payment_statement("op-st-pay-1")

      assert untouched == %{
               "payment_operation_id" => "op-st-pay-1",
               "original_group_id" => "g-st-src",
               "recorded_cents" => 4000,
               "held_cents" => 4000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end
  end

  describe "durability" do
    test "an identical transfer retry replays its result without moving funding again" do
      conn = build_conn()
      open_group!(conn, "g-dur-src")
      apply_op!(conn, payment_operation("g-dur-src", 5000, operation_id: "op-dur-pay"))
      open_group!(conn, "g-dur-dst")

      operation = transfer_operation("g-dur-src", "g-dur-dst", 2000, operation_id: "op-dur-tr")
      [first] = submit!(conn, [operation])
      assert first["status"] == "applied"

      [retry] = submit!(conn, [operation])
      assert retry == first

      assert group_data("g-dur-src")["cash_paid_cents"] == 3000
      assert group_data("g-dur-dst")["cash_paid_cents"] == 2000
      assert group_data("g-dur-src")["revision"] == 3
      assert group_data("g-dur-dst")["revision"] == 2
      assert ledger()["cash_held_cents"] == 5000

      # A different payload under the same identifier conflicts.
      conflicting = transfer_operation("g-dur-src", "g-dur-dst", 1000, operation_id: "op-dur-tr")
      [conflict] = submit!(conn, [conflicting])

      assert conflict["code"] == "operation_id_conflict"
      assert group_data("g-dur-dst")["cash_paid_cents"] == 2000
    end

    test "a rejected transfer is remembered durably" do
      conn = build_conn()
      open_group!(conn, "g-rejd-src")
      apply_op!(conn, payment_operation("g-rejd-src", 5000, operation_id: "op-rejd-pay"))
      open_group!(conn, "g-rejd-dst")
      apply_op!(conn, payment_operation("g-rejd-dst", 12_000, operation_id: "op-rejd-full"))

      operation = transfer_operation("g-rejd-src", "g-rejd-dst", 3000, operation_id: "op-rejd-tr")
      [first] = submit!(conn, [operation])
      assert first["code"] == "transfer_exceeds_outstanding"

      # The destination's deposit reopens, but the retry observes the
      # stored rejection rather than moving the funding.
      apply_op!(conn, reduce_operation("op-rejd-full", 12_000, operation_id: "op-rejd-reduce"))

      [retry] = submit!(conn, [operation])
      assert retry == first
      assert group_data("g-rejd-dst")["cash_paid_cents"] == 0
    end

    test "a transfer observes earlier operations in the same batch" do
      conn = build_conn()

      [_, _, paid, transferred] =
        submit!(conn, [
          open_operation("g-batch-src", operation_id: "op-batch-open-1"),
          open_operation("g-batch-dst", operation_id: "op-batch-open-2"),
          payment_operation("g-batch-src", 4000, operation_id: "op-batch-pay"),
          transfer_operation("g-batch-src", "g-batch-dst", 1500, operation_id: "op-batch-tr")
        ])

      assert paid["status"] == "applied"
      assert transferred["status"] == "applied"
      assert transferred["source_outstanding_deposit_cents"] == 9500
      assert transferred["destination_outstanding_deposit_cents"] == 10_500
      assert group_data("g-batch-dst")["cash_paid_cents"] == 1500
    end
  end
end
