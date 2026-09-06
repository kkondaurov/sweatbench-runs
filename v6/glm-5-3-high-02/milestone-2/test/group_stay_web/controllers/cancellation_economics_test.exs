defmodule GroupStayWeb.CancellationEconomicsTest do
  @moduledoc """
  Product request 02: policy versions, hotel credit on cancellation, and
  applying credit to deposits.
  """

  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @guest "guest-22"
  @booked_on "2026-10-03"
  @arrival_on "2027-03-10"
  @departure_on "2027-03-13"
  # One room, three nights at 15000: lodging 45000, flexible deposit 9000.

  defp open_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, @guest),
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
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

  defp cancel_operation(group_id, opts \\ []) do
    operation = %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id
    }

    case Keyword.get(opts, :refund_method) do
      nil -> operation
      refund_method -> Map.put(operation, "refund_method", refund_method)
    end
  end

  defp credit_operation(group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-credit-#{group_id}-#{amount_cents}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

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

  # Funds the guest with a credit lot by cancelling a paid group in credit.
  defp issue_lot!(conn, group_id, cash_cents, cancelled_on) do
    open_group!(conn, group_id)
    submit!(conn, [payment_operation(group_id, cash_cents, occurred_on: "2026-10-05")])

    apply_op!(
      conn,
      cancel_operation(group_id, occurred_on: cancelled_on, refund_method: "hotel_credit")
    )
  end

  defp group_data(group_id) do
    conn = get(build_conn(), "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp ledger(on \\ nil) do
    conn = get(build_conn(), "/api/v1/ledger" <> on_query(on))
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp guest_credit(guest_id, on \\ nil) do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> on_query(on))
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp on_query(nil), do: ""
  defp on_query(on), do: "?on=#{on}"

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window" do
      conn = build_conn()
      open_group!(conn, "g-flex14", occurred_on: "2026-12-31")

      data = group_data("g-flex14")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-02-24"

      submit!(conn, [payment_operation("g-flex14", 1000, occurred_on: "2026-12-31")])

      # Cancelling on refundable_until is still refundable.
      result = apply_op!(conn, cancel_operation("g-flex14", occurred_on: "2027-02-24"))
      assert result["refunded_cents"] == 1000
      assert result["retained_cents"] == 0
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window" do
      conn = build_conn()
      open_group!(conn, "g-flex30", occurred_on: "2027-01-01")
      open_group!(conn, "g-flex30-edge", occurred_on: "2027-06-01")

      assert group_data("g-flex30")["policy_version"] == "flex-30"
      assert group_data("g-flex30")["refundable_until"] == "2027-02-08"

      submit!(conn, [payment_operation("g-flex30", 1000, occurred_on: "2027-01-02")])
      submit!(conn, [payment_operation("g-flex30-edge", 1000, occurred_on: "2027-06-02")])

      # 29 days before arrival is no longer refundable.
      result = apply_op!(conn, cancel_operation("g-flex30", occurred_on: "2027-02-09"))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1000
      assert result["credit_issued_cents"] == 0

      # Exactly 30 days before arrival still is.
      result = apply_op!(conn, cancel_operation("g-flex30-edge", occurred_on: "2027-02-08"))
      assert result["refunded_cents"] == 1000
      assert result["retained_cents"] == 0
    end

    test "advance purchase groups are non-refundable" do
      conn = build_conn()
      open_group!(conn, "g-adv", rate_plan: "advance_purchase")

      data = group_data("g-adv")
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil

      submit!(conn, [payment_operation("g-adv", 45_000, occurred_on: "2026-10-05")])
      result = apply_op!(conn, cancel_operation("g-adv", occurred_on: "2026-10-10"))
      assert result["retained_cents"] == 45_000
    end

    test "rescheduling never moves a group to a newer policy" do
      conn = build_conn()
      open_group!(conn, "g-move-policy", occurred_on: "2026-10-03")

      result =
        apply_op!(conn, %{
          "operation_id" => "op-move-g-move-policy",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-10",
          "group_id" => "g-move-policy",
          "new_arrival_on" => "2027-06-10"
        })

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-05-27"

      data = group_data("g-move-policy")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-05-27"
    end

    test "groups without a stored policy keep the policy their booking date implies" do
      # A group created by an earlier release, before the column existed.
      {:ok, _group} =
        Repo.insert(%Group{
          group_id: "g-legacy",
          guest_id: @guest,
          property_id: "ams-canal",
          booked_on: ~D[2026-05-01],
          arrival_on: ~D[2027-03-10],
          departure_on: ~D[2027-03-13],
          rate_plan: "flexible",
          status: "active",
          revision: 1,
          lodging_total_cents: 45_000,
          deposit_due_cents: 9_000
        })

      data = group_data("g-legacy")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-02-24"
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 0
    end
  end

  describe "issuing credit on cancellation" do
    test "a refundable cancellation with hotel credit issues a lot worth 110%" do
      conn = build_conn()
      open_group!(conn, "g-issue")
      submit!(conn, [payment_operation("g-issue", 5000, occurred_on: "2026-10-05")])

      result =
        apply_op!(
          conn,
          cancel_operation("g-issue", occurred_on: "2027-01-05", refund_method: "hotel_credit")
        )

      assert result == %{
               "operation_id" => "op-cancel-g-issue",
               "status" => "applied",
               "group_id" => "g-issue",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             }

      assert ledger("2027-01-05") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }

      # Available through 2028-01-05 (365 days later), expiring the following day.
      assert guest_credit(@guest, "2027-01-05") == %{
               "guest_id" => @guest,
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-issue",
                   "remaining_cents" => 5500,
                   "expires_on" => "2028-01-06"
                 }
               ]
             }
    end

    test "the 10% bonus rounds to the nearest cent, half upward" do
      conn = build_conn()

      open_group!(conn, "g-bonus-up")
      submit!(conn, [payment_operation("g-bonus-up", 4545, occurred_on: "2026-10-05")])

      result =
        apply_op!(
          conn,
          cancel_operation("g-bonus-up", occurred_on: "2027-01-05", refund_method: "hotel_credit")
        )

      # 4545 * 10% = 454.5, which rounds up to 455.
      assert result["credit_issued_cents"] == 5000

      open_group!(conn, "g-bonus-down")
      submit!(conn, [payment_operation("g-bonus-down", 3333, occurred_on: "2026-10-05")])

      result =
        apply_op!(
          conn,
          cancel_operation("g-bonus-down",
            occurred_on: "2027-01-05",
            refund_method: "hotel_credit"
          )
        )

      # 3333 * 10% = 333.3, which rounds down to 333.
      assert result["credit_issued_cents"] == 3666
    end

    test "hotel credit is not a way around a non-refundable policy" do
      conn = build_conn()
      open_group!(conn, "g-no-credit")
      submit!(conn, [payment_operation("g-no-credit", 5000, occurred_on: "2026-10-05")])

      # 2027-03-01 is nine days before the 2027-03-10 arrival.
      [result] =
        submit!(conn, [
          cancel_operation("g-no-credit",
            occurred_on: "2027-03-01",
            refund_method: "hotel_credit"
          )
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"
      assert result["operation_id"] == "op-cancel-g-no-credit"

      data = group_data("g-no-credit")
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert ledger("2027-03-01")["cash_held_cents"] == 5000
      assert guest_credit(@guest, "2027-03-01")["available_cents"] == 0

      # The same applies to advance purchase.
      open_group!(conn, "g-ap-credit", rate_plan: "advance_purchase")

      [result] =
        submit!(conn, [
          cancel_operation("g-ap-credit",
            occurred_on: "2026-10-10",
            refund_method: "hotel_credit"
          )
        ])

      assert result["code"] == "refund_method_not_available"
      assert group_data("g-ap-credit")["status"] == "active"
    end

    test "an unknown refund method is rejected with invalid_operation" do
      conn = build_conn()
      open_group!(conn, "g-bad-method")

      [result] =
        submit!(conn, [
          cancel_operation("g-bad-method", occurred_on: "2027-01-05", refund_method: "cheque")
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
      assert group_data("g-bad-method")["revision"] == 1
    end

    test "an explicit cash refund method settles like an omitted one" do
      conn = build_conn()
      open_group!(conn, "g-explicit-cash")
      submit!(conn, [payment_operation("g-explicit-cash", 1000, occurred_on: "2026-10-05")])

      result =
        apply_op!(
          conn,
          cancel_operation("g-explicit-cash", occurred_on: "2027-01-05", refund_method: "cash")
        )

      assert result["refunded_cents"] == 1000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert ledger("2027-01-05")["cash_refunded_cents"] == 1000
      assert ledger("2027-01-05")["cash_converted_to_credit_cents"] == 0
    end

    test "a refundable credit cancellation without cash issues no lot" do
      conn = build_conn()
      open_group!(conn, "g-unpaid-credit")

      result =
        apply_op!(
          conn,
          cancel_operation("g-unpaid-credit",
            occurred_on: "2027-01-05",
            refund_method: "hotel_credit"
          )
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert guest_credit(@guest, "2027-01-05")["available_cents"] == 0
    end
  end

  describe "apply_hotel_credit" do
    test "applies credit to an active group's deposit" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 5000, "2027-01-05")

      open_group!(conn, "g-use",
        occurred_on: "2027-01-10",
        arrival_on: "2027-04-10",
        departure_on: "2027-04-13"
      )

      result = apply_op!(conn, credit_operation("g-use", 2000, occurred_on: "2027-01-15"))

      assert result == %{
               "operation_id" => "op-credit-g-use-2000",
               "status" => "applied",
               "group_id" => "g-use",
               "amount_cents" => 2000,
               "outstanding_deposit_cents" => 7000,
               "revision" => 2
             }

      data = group_data("g-use")
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 2000
      assert data["deposit_paid_cents"] == 2000
      assert data["outstanding_deposit_cents"] == 7000

      # Applying credit does not change the liability: the applied amount
      # still counts while it funds the group.
      assert ledger("2027-01-15")["credit_liability_cents"] == 5500

      assert guest_credit(@guest, "2027-01-15") == %{
               "guest_id" => @guest,
               "available_cents" => 3500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-src",
                   "remaining_cents" => 3500,
                   "expires_on" => "2028-01-06"
                 }
               ]
             }
    end

    test "cash and credit share the outstanding deposit" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 5000, "2027-01-05")

      open_group!(conn, "g-mixed-fund", occurred_on: "2027-01-10")
      submit!(conn, [payment_operation("g-mixed-fund", 4000, occurred_on: "2027-01-11")])
      apply_op!(conn, credit_operation("g-mixed-fund", 3000, occurred_on: "2027-01-12"))

      data = group_data("g-mixed-fund")
      assert data["cash_paid_cents"] == 4000
      assert data["credit_paid_cents"] == 3000
      assert data["deposit_paid_cents"] == 7000
      assert data["outstanding_deposit_cents"] == 2000

      # Credit cannot exceed the remaining outstanding deposit.
      [result] =
        submit!(conn, [credit_operation("g-mixed-fund", 2001, occurred_on: "2027-01-13")])

      assert result["code"] == "payment_exceeds_outstanding"
      assert group_data("g-mixed-fund")["revision"] == 3

      # Exactly the outstanding deposit is fine.
      result = apply_op!(conn, credit_operation("g-mixed-fund", 2000, occurred_on: "2027-01-14"))
      assert result["outstanding_deposit_cents"] == 0
    end

    test "credit is consumed from the earliest-expiring lot first" do
      conn = build_conn()

      # The earlier cancellation expires first.
      issue_lot!(conn, "g-lot-early", 1000, "2026-11-01")
      issue_lot!(conn, "g-lot-late", 1000, "2026-12-01")

      open_group!(conn, "g-order-use", occurred_on: "2027-01-01")
      apply_op!(conn, credit_operation("g-order-use", 1200, occurred_on: "2027-02-01"))

      # The lot expiring 2027-11-02 is exhausted; the later one loses 100.
      assert guest_credit(@guest, "2027-02-01") == %{
               "guest_id" => @guest,
               "available_cents" => 1000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-lot-late",
                   "remaining_cents" => 1000,
                   "expires_on" => "2027-12-02"
                 }
               ]
             }
    end

    test "lots with equal expiry are consumed by source_operation_id" do
      conn = build_conn()

      # Same cancellation date, so both lots expire 2027-11-02.
      issue_lot!(conn, "g-tie-b", 1000, "2026-11-01")
      issue_lot!(conn, "g-tie-a", 1000, "2026-11-01")

      open_group!(conn, "g-tie-use", occurred_on: "2027-01-01")
      apply_op!(conn, credit_operation("g-tie-use", 1200, occurred_on: "2027-02-01"))

      # op-cancel-g-tie-a goes first: fully consumed, then 100 from b.
      assert guest_credit(@guest, "2027-02-01")["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-g-tie-b",
                 "remaining_cents" => 1000,
                 "expires_on" => "2027-11-02"
               }
             ]
    end

    test "rejects applying more credit than the guest has with insufficient_credit" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-short", occurred_on: "2027-01-01")

      [result] =
        submit!(conn, [credit_operation("g-short", 1101, occurred_on: "2027-02-01")])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"

      data = group_data("g-short")
      assert data["revision"] == 1
      assert data["credit_paid_cents"] == 0
      assert guest_credit(@guest, "2027-02-01")["available_cents"] == 1100
    end

    test "credit expiry is evaluated as of the operation's occurred_on" do
      conn = build_conn()
      # This lot expires on 2027-11-02.
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-expiry", occurred_on: "2027-01-01")

      # The day the lot expires it is no longer usable.
      [result] =
        submit!(conn, [credit_operation("g-expiry", 1000, occurred_on: "2027-11-02")])

      assert result["code"] == "insufficient_credit"

      # The day before it still is.
      result = apply_op!(conn, credit_operation("g-expiry", 1000, occurred_on: "2027-11-01"))
      assert result["status"] == "applied"
    end

    test "rejects unusable amounts with invalid_amount" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")
      open_group!(conn, "g-amount", occurred_on: "2027-01-01")

      for amount <- [0, -100, "100", 100.5, nil] do
        [result] =
          submit!(conn, [
            Map.put(
              credit_operation("g-amount", 1, occurred_on: "2027-02-01"),
              "amount_cents",
              amount
            )
          ])

        assert result["code"] == "invalid_amount", inspect(amount)
      end

      [result] =
        submit!(conn, [
          Map.delete(credit_operation("g-amount", 1, occurred_on: "2027-02-01"), "amount_cents")
        ])

      assert result["code"] == "invalid_amount"
      assert group_data("g-amount")["revision"] == 1
    end

    test "uses the existing group errors for missing and inactive groups" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      [result] =
        submit!(conn, [credit_operation("g-missing", 100, occurred_on: "2027-02-01")])

      assert result["code"] == "group_not_found"

      open_group!(conn, "g-done", occurred_on: "2027-01-01")
      apply_op!(conn, cancel_operation("g-done", occurred_on: "2027-02-01"))

      [result] =
        submit!(conn, [credit_operation("g-done", 100, occurred_on: "2027-02-02")])

      assert result["code"] == "group_not_active"
    end

    test "follows the revision contract" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")
      open_group!(conn, "g-rev", occurred_on: "2027-01-01")

      # A stale revision is rejected before the credit rules, even when the
      # amount could never be covered.
      [result] =
        submit!(conn, [
          credit_operation("g-rev", 999_999, occurred_on: "2027-02-01")
          |> Map.put("expected_revision", 7)
        ])

      assert result == %{
               "operation_id" => "op-credit-g-rev-999999",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-rev",
               "expected_revision" => 7,
               "actual_revision" => 1
             }

      # A rejected attempt does not advance the revision.
      [rejected] =
        submit!(conn, [credit_operation("g-rev", 5000, occurred_on: "2027-02-01")])

      assert rejected["code"] == "insufficient_credit"

      result =
        apply_op!(
          conn,
          credit_operation("g-rev", 500, occurred_on: "2027-02-01")
          |> Map.put("expected_revision", 1)
        )

      assert result["revision"] == 2

      [stale] =
        submit!(conn, [
          credit_operation("g-rev", 100, occurred_on: "2027-02-01")
          |> Map.put("expected_revision", 1)
        ])

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
    end

    test "operations within one batch observe earlier applications" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      assert [open, credit, over] =
               submit!(conn, [
                 open_operation("g-batch", occurred_on: "2027-01-01"),
                 credit_operation("g-batch", 1000, occurred_on: "2027-01-02"),
                 credit_operation("g-batch", 101, occurred_on: "2027-01-03")
               ])

      assert open["status"] == "applied"
      assert credit["status"] == "applied"
      assert credit["outstanding_deposit_cents"] == 8000
      assert credit["revision"] == 2
      assert over["code"] == "insufficient_credit"
    end
  end

  describe "settling a group funded by credit" do
    test "refundable cancellation returns applied credit without a second bonus" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-back",
        occurred_on: "2027-01-10",
        arrival_on: "2027-06-10",
        departure_on: "2027-06-13"
      )

      submit!(conn, [payment_operation("g-back", 100, occurred_on: "2027-02-01")])
      apply_op!(conn, credit_operation("g-back", 1100, occurred_on: "2027-02-02"))

      result = apply_op!(conn, cancel_operation("g-back", occurred_on: "2027-03-01"))

      # Only the cash was refunded; the credit returned to its lot, whole.
      assert result["refunded_cents"] == 100
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 4

      assert guest_credit(@guest, "2027-03-01") == %{
               "guest_id" => @guest,
               "available_cents" => 1100,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-src",
                   "remaining_cents" => 1100,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger("2027-03-01")["credit_liability_cents"] == 1100
      assert ledger("2027-03-01")["cash_converted_to_credit_cents"] == 1000

      data = group_data("g-back")
      assert data["status"] == "cancelled"
      assert data["cash_paid_cents"] == 100
      assert data["credit_paid_cents"] == 1100
      assert data["deposit_paid_cents"] == 1200
    end

    test "refundable credit cancellation converts cash and restores credit" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-mixed", occurred_on: "2027-01-10")
      submit!(conn, [payment_operation("g-mixed", 1000, occurred_on: "2027-01-11")])
      apply_op!(conn, credit_operation("g-mixed", 500, occurred_on: "2027-01-12"))

      result =
        apply_op!(
          conn,
          cancel_operation("g-mixed", occurred_on: "2027-02-01", refund_method: "hotel_credit")
        )

      # The bonus applies only to the cash; restored credit gets no second one.
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 1100

      assert guest_credit(@guest, "2027-02-01") == %{
               "guest_id" => @guest,
               "available_cents" => 2200,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-src",
                   "remaining_cents" => 1100,
                   "expires_on" => "2027-11-02"
                 },
                 %{
                   "source_operation_id" => "op-cancel-g-mixed",
                   "remaining_cents" => 1100,
                   "expires_on" => "2028-02-02"
                 }
               ]
             }

      assert ledger("2027-02-01")["cash_converted_to_credit_cents"] == 2000
      assert ledger("2027-02-01")["credit_liability_cents"] == 2200
    end

    test "non-refundable cancellation retains cash and consumes applied credit" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-burn", occurred_on: "2027-01-10")
      submit!(conn, [payment_operation("g-burn", 1000, occurred_on: "2027-01-11")])
      apply_op!(conn, credit_operation("g-burn", 1000, occurred_on: "2027-01-12"))

      # 2027-03-01 is nine days before the 2027-03-10 arrival.
      result = apply_op!(conn, cancel_operation("g-burn", occurred_on: "2027-03-01"))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1000
      assert result["credit_issued_cents"] == 0

      # The applied credit is consumed, not restored: only the lot's
      # untouched remainder (from the bonus) is still available.
      assert guest_credit(@guest, "2027-03-01") == %{
               "guest_id" => @guest,
               "available_cents" => 100,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-src",
                   "remaining_cents" => 100,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger("2027-03-01")["cash_retained_cents"] == 1000
      assert ledger("2027-03-01")["credit_liability_cents"] == 100
    end

    test "restored credit whose lot already expired does not become available again" do
      conn = build_conn()
      # This lot expires on 2027-11-02.
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-exp-restore",
        occurred_on: "2026-11-05",
        arrival_on: "2028-06-01",
        departure_on: "2028-06-04"
      )

      apply_op!(conn, credit_operation("g-exp-restore", 500, occurred_on: "2027-06-01"))

      # While funding the group, expiry is paused.
      assert ledger("2027-10-01")["credit_liability_cents"] == 1100
      assert ledger("2028-01-10")["credit_liability_cents"] == 500

      result = apply_op!(conn, cancel_operation("g-exp-restore", occurred_on: "2028-01-10"))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # The lot expired 2027-11-02, so the restored amount is not available.
      assert guest_credit(@guest, "2028-01-10") == %{
               "guest_id" => @guest,
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger("2028-01-10")["credit_liability_cents"] == 0
    end
  end

  describe "credit and ledger reads" do
    test "credit reads report expiry as of the on date" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      assert guest_credit(@guest, "2027-11-01")["available_cents"] == 1100
      assert guest_credit(@guest, "2027-11-01")["lots"] != []

      assert guest_credit(@guest, "2027-11-02") == %{
               "guest_id" => @guest,
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger("2027-11-01")["credit_liability_cents"] == 1100
      assert ledger("2027-11-02")["credit_liability_cents"] == 0
    end

    test "a guest without credit has none available" do
      assert guest_credit("guest-none", "2027-01-01") == %{
               "guest_id" => "guest-none",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "lots are returned ordered by expiry then source_operation_id" do
      conn = build_conn()

      issue_lot!(conn, "g-list-late", 1000, "2026-12-01")
      issue_lot!(conn, "g-list-b", 1000, "2027-01-05")
      issue_lot!(conn, "g-list-a", 1000, "2027-01-05")

      lots = guest_credit(@guest, "2027-02-01")["lots"]

      assert Enum.map(lots, & &1["source_operation_id"]) == [
               "op-cancel-g-list-late",
               "op-cancel-g-list-a",
               "op-cancel-g-list-b"
             ]
    end

    test "invalid on dates are rejected" do
      conn = get(build_conn(), "/api/v1/guests/#{@guest}/credit?on=not-a-date")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}

      conn = get(build_conn(), "/api/v1/ledger?on=2027-13-01")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end

    test "credit is guest-scoped" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 1000, "2026-11-01")

      open_group!(conn, "g-other-guest", occurred_on: "2027-01-01", guest_id: "guest-99")

      [result] =
        submit!(conn, [credit_operation("g-other-guest", 100, occurred_on: "2027-02-01")])

      assert result["code"] == "insufficient_credit"
    end
  end
end
