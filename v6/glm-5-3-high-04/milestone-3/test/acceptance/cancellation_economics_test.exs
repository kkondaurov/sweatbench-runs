defmodule GroupStayWeb.CancellationEconomicsTest do
  @moduledoc """
  Acceptance tests for the cancellation-economics release: policy versions,
  hotel credit issued on cancellation, applying credit to deposits, settling
  groups funded by credit, and the credit and ledger reads.
  """

  use GroupStayWeb.ConnCase, async: false

  @batch_url "/api/v1/partner-batches"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  # Operations are idempotent by operation_id, so distinct operations in a
  # test need distinct identifiers.
  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-open"),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 3_000
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp ledger(conn, on \\ nil) do
    url = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"
    conn = get(conn, url)
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp guest_credit(conn, guest_id, on \\ nil) do
    url =
      if on,
        do: "/api/v1/guests/#{guest_id}/credit?on=#{on}",
        else: "/api/v1/guests/#{guest_id}/credit"

    conn = get(conn, url)
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  # Cancels `group_id` refundably with hotel credit, leaving the guest with a
  # credit lot worth 110% of the cash paid.
  defp issue_credit!(conn, group_id, operation_id, cash_cents, cancel_overrides \\ %{}) do
    open_group!(conn, %{"group_id" => group_id})

    apply_operation!(
      conn,
      payment_operation(%{"group_id" => group_id, "amount_cents" => cash_cents})
    )

    result =
      apply_operation!(
        conn,
        cancel_operation(
          Map.merge(
            %{
              "group_id" => group_id,
              "operation_id" => operation_id,
              "refund_method" => "hotel_credit"
            },
            cancel_overrides
          )
        )
      )

    assert result["credit_issued_cents"] == with_bonus(cash_cents)
    result
  end

  defp with_bonus(cash_cents), do: div(cash_cents * 110 + 50, 100)

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      group = fetch_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-24"

      apply_operation!(conn, payment_operation(%{"occurred_on" => "2027-01-05"}))

      result = apply_operation!(conn, cancel_operation(%{"occurred_on" => "2027-02-24"}))
      assert result["refunded_cents"] == 5_000
      assert result["retained_cents"] == 0
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      })

      group = fetch_group(conn, "group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-05-11"

      apply_operation!(conn, payment_operation(%{"occurred_on" => "2027-02-01"}))

      # Cancellation on refundable_until is refundable...
      result = apply_operation!(conn, cancel_operation(%{"occurred_on" => "2027-05-11"}))
      assert result["refunded_cents"] == 5_000
    end

    test "flex-30 groups cancelled inside the window are non-refundable", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      })

      apply_operation!(conn, payment_operation(%{"occurred_on" => "2027-02-01"}))

      # ...the day after refundable_until it is not (29 days before arrival).
      result = apply_operation!(conn, cancel_operation(%{"occurred_on" => "2027-05-12"}))
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5_000
    end

    test "advance purchase groups report the non-refundable policy", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2027-02-01",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13",
        "rate_plan" => "advance_purchase"
      })

      group = fetch_group(conn, "group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      open_group!(conn, %{
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-01-02",
        "departure_on" => "2027-01-05"
      })

      result =
        apply_operation!(
          conn,
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-06-10"
          }
        )

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-05-27"

      group = fetch_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-05-27"

      # Still flex-14: cancelling 14 days before the new arrival refunds.
      apply_operation!(conn, payment_operation(%{"occurred_on" => "2027-01-06"}))

      result = apply_operation!(conn, cancel_operation(%{"occurred_on" => "2027-05-27"}))
      assert result["refunded_cents"] == 5_000
    end
  end

  describe "issuing credit on cancellation" do
    test "converts refundable cash into a 110% credit lot", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation())

      result =
        apply_operation!(
          conn,
          cancel_operation(%{"operation_id" => "op-cancel-e", "refund_method" => "hotel_credit"})
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 5_500
      assert result["revision"] == 3

      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-e",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "credit_liability_cents" => 5_500
             }
    end

    test "rounds the 10% bonus to the nearest cent, halves upward", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, payment_operation(%{"amount_cents" => 4_545}))

      result =
        apply_operation!(
          conn,
          cancel_operation(%{"refund_method" => "hotel_credit"})
        )

      # 4545 * 1.1 = 4999.5 -> 5000.
      assert result["credit_issued_cents"] == 5_000
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 4_545
    end

    test "explicit cash refund_method preserves the original settlement", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation())

      result = apply_operation!(conn, cancel_operation(%{"refund_method" => "cash"}))

      assert result["refunded_cents"] == 5_000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "rejects hotel credit for a non-refundable cancellation and leaves the group active",
         %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation())

      result =
        reject_operation!(
          conn,
          cancel_operation(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        )

      assert result["code"] == "refund_method_not_available"

      group = fetch_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["cash_held_cents"] == 5_000
      assert ledger(conn)["credit_liability_cents"] == 0

      # A later cash cancellation still settles normally.
      result = apply_operation!(conn, cancel_operation(%{"occurred_on" => "2026-11-27"}))
      assert result["retained_cents"] == 5_000
    end

    test "rejects hotel credit for advance purchase cancellations", %{conn: conn} do
      open_group!(conn, %{"rate_plan" => "advance_purchase"})

      result =
        reject_operation!(conn, cancel_operation(%{"refund_method" => "hotel_credit"}))

      assert result["code"] == "refund_method_not_available"
      assert fetch_group(conn, "group-81")["status"] == "active"
    end

    test "rejects unknown refund methods with invalid_operation", %{conn: conn} do
      open_group!(conn)

      for refund_method <- ["bitcoin", "", 5, true] do
        result = reject_operation!(conn, cancel_operation(%{"refund_method" => refund_method}))
        assert result["code"] == "invalid_operation", "for #{inspect(refund_method)}"
      end

      assert fetch_group(conn, "group-81")["revision"] == 1
    end

    test "an unpaid refundable cancellation with hotel credit issues nothing", %{conn: conn} do
      open_group!(conn)

      result = apply_operation!(conn, cancel_operation(%{"refund_method" => "hotel_credit"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
    end
  end

  describe "applying credit" do
    setup %{conn: conn} do
      issue_credit!(conn, "group-src", "op-cancel-src", 5_000)

      open_group!(conn, %{
        "group_id" => "group-81",
        "occurred_on" => "2026-12-01",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      :ok
    end

    test "applies unexpired credit to the outstanding deposit", %{conn: conn} do
      op = apply_credit_operation()
      result = apply_operation!(conn, op)

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 3_000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 2
             }

      group = fetch_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 3_000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 3_000
      assert group["outstanding_deposit_cents"] == 16_500

      assert guest_credit(conn, "guest-22")["available_cents"] == 2_500

      # Applying credit does not change the liability: 2500 still available
      # plus 3000 funding the active group.
      assert ledger(conn)["credit_liability_cents"] == 5_500
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "rejects amounts the guest cannot cover with insufficient_credit", %{conn: conn} do
      result = reject_operation!(conn, apply_credit_operation(%{"amount_cents" => 5_501}))

      assert result["code"] == "insufficient_credit"

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 1
      assert group["credit_paid_cents"] == 0

      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500
      assert ledger(conn)["credit_liability_cents"] == 5_500
    end

    test "rejects credit exceeding the outstanding deposit", %{conn: conn} do
      apply_operation!(
        conn,
        payment_operation(%{"occurred_on" => "2026-12-02", "amount_cents" => 15_000})
      )

      result = reject_operation!(conn, apply_credit_operation(%{"amount_cents" => 5_000}))

      assert result["code"] == "payment_exceeds_outstanding"

      assert fetch_group(conn, "group-81")["credit_paid_cents"] == 0
      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500
    end

    test "rejects unusable amounts with invalid_amount", %{conn: conn} do
      for amount <- [0, -100, "500", 1.5, nil] do
        result = reject_operation!(conn, apply_credit_operation(%{"amount_cents" => amount}))
        assert result["code"] == "invalid_amount", "for #{inspect(amount)}"
      end
    end

    test "resolves group existence and activity with the existing errors", %{conn: conn} do
      result =
        reject_operation!(conn, apply_credit_operation(%{"group_id" => "group-missing"}))

      assert result["code"] == "group_not_found"

      apply_operation!(conn, cancel_operation(%{"occurred_on" => "2027-01-01"}))

      result = reject_operation!(conn, apply_credit_operation())
      assert result["code"] == "group_not_active"
    end

    test "rejects an operation missing its group identifier with invalid_operation", %{conn: conn} do
      result = reject_operation!(conn, apply_credit_operation(%{"group_id" => nil}))

      assert result["code"] == "invalid_operation"
    end

    test "credit is scoped to the group's guest", %{conn: conn} do
      open_group!(conn, %{
        "group_id" => "group-other-guest",
        "guest_id" => "guest-99",
        "occurred_on" => "2026-12-01",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      result =
        reject_operation!(
          conn,
          apply_credit_operation(%{"group_id" => "group-other-guest", "amount_cents" => 100})
        )

      assert result["code"] == "insufficient_credit"
    end

    test "an operation observes credit issued earlier in the same batch", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_operation(%{"group_id" => "group-batch-src", "operation_id" => "op-1"}),
          payment_operation(%{
            "group_id" => "group-batch-src",
            "operation_id" => "op-2",
            "amount_cents" => 2_000
          }),
          cancel_operation(%{
            "group_id" => "group-batch-src",
            "operation_id" => "op-3",
            "refund_method" => "hotel_credit"
          }),
          %{
            "operation_id" => "op-4",
            "type" => "open_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-batch-tgt",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13",
            "rate_plan" => "flexible",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          },
          apply_credit_operation(%{
            "group_id" => "group-batch-tgt",
            "operation_id" => "op-5",
            "amount_cents" => 2_200
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["status"]) == [
               "applied",
               "applied",
               "applied",
               "applied",
               "applied"
             ]

      assert Enum.at(results, 2)["credit_issued_cents"] == 2_200
      assert Enum.at(results, 4)["outstanding_deposit_cents"] == 9_000 - 2_200

      # The lot issued within the batch was fully consumed; only the setup
      # lot's credit remains.
      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500
    end

    test "follows the revision contract", %{conn: conn} do
      result =
        apply_operation!(conn, apply_credit_operation(%{"expected_revision" => 1}))

      assert result["revision"] == 2

      # Revision is checked before the domain rules...
      result =
        reject_operation!(
          conn,
          apply_credit_operation(%{"expected_revision" => 1, "amount_cents" => 999_999})
        )

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2

      # ...and a rejected attempt does not advance the revision.
      result =
        reject_operation!(conn, apply_credit_operation(%{"amount_cents" => 999_999}))

      assert result["code"] == "insufficient_credit"
      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "consumes lots by earliest expiry", %{conn: conn} do
      # This lot expires 2027-11-21, earlier than the setup lot's 2027-11-27.
      issue_credit!(
        conn,
        "group-src-b",
        "op-cancel-src-b",
        1_000,
        %{"occurred_on" => "2026-11-20"}
      )

      apply_operation!(conn, apply_credit_operation(%{"amount_cents" => 6_000}))

      credit = guest_credit(conn, "guest-22")

      # The earliest-expiring lot was consumed first and is now exhausted, so
      # only the setup lot's remainder is left.
      assert credit["available_cents"] == 600
      assert [%{"source_operation_id" => source}] = credit["lots"]
      assert source == "op-cancel-src"
    end

    test "breaks expiry ties by source_operation_id", %{conn: conn} do
      # Both lots expire 2027-11-27, so the 3000 comes from the
      # alphabetically-first source operation.
      issue_credit!(conn, "group-src-z", "op-cancel-z", 1_000)

      apply_operation!(conn, apply_credit_operation(%{"amount_cents" => 3_000}))

      credit = guest_credit(conn, "guest-22")
      lots = Enum.map(credit["lots"], &{&1["source_operation_id"], &1["remaining_cents"]})
      assert lots == [{"op-cancel-src", 2_500}, {"op-cancel-z", 1_100}]
    end

    test "evaluates lot expiry using occurred_on", %{conn: conn} do
      # The lot is available through 2027-11-26 and expires 2027-11-27.
      result =
        apply_operation!(
          conn,
          apply_credit_operation(%{"occurred_on" => "2027-11-26", "amount_cents" => 100})
        )

      assert result["status"] == "applied"

      result =
        reject_operation!(
          conn,
          apply_credit_operation(%{"occurred_on" => "2027-11-27", "amount_cents" => 100})
        )

      assert result["code"] == "insufficient_credit"
    end
  end

  describe "settling a group funded by credit" do
    setup %{conn: conn} do
      issue_credit!(conn, "group-src", "op-cancel-src", 5_000)

      open_group!(conn, %{
        "group_id" => "group-81",
        "occurred_on" => "2026-12-01",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      apply_operation!(
        conn,
        payment_operation(%{"occurred_on" => "2026-12-02", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        apply_credit_operation(%{"occurred_on" => "2026-12-03", "amount_cents" => 3_000})
      )

      :ok
    end

    test "refunds only the cash and restores credit on a cash settlement", %{conn: conn} do
      result = apply_operation!(conn, cancel_operation(%{"occurred_on" => "2026-12-05"}))

      assert result["refunded_cents"] == 5_000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "credit_liability_cents" => 5_500
             }
    end

    test "converts the cash and restores the credit on a hotel-credit settlement", %{conn: conn} do
      result =
        apply_operation!(
          conn,
          cancel_operation(%{
            "occurred_on" => "2026-12-05",
            "operation_id" => "op-cancel-mixed",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 5_500

      # The restored credit keeps its original expiry and gets no second
      # bonus; the cash becomes a new 110% lot.
      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-src",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-27"
                 },
                 %{
                   "source_operation_id" => "op-cancel-mixed",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-12-06"
                 }
               ]
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             }
    end

    test "retains the cash and consumes the credit on a non-refundable settlement", %{conn: conn} do
      result =
        apply_operation!(
          conn,
          cancel_operation(%{"occurred_on" => "2028-01-05"})
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5_000
      assert result["credit_issued_cents"] == 0

      # The applied credit was consumed, not restored.
      assert guest_credit(conn, "guest-22")["available_cents"] == 2_500
      assert ledger(conn)["credit_liability_cents"] == 2_500
      assert ledger(conn)["cash_retained_cents"] == 5_000
    end
  end

  describe "restoring credit whose lot already expired" do
    test "the restored amount expires immediately instead of becoming available again", %{
      conn: conn
    } do
      # A lot worth 5500 expiring 2027-06-01, issued by a cancellation on
      # 2026-05-31.
      issue_credit!(
        conn,
        "group-old",
        "op-cancel-old",
        5_000,
        %{"occurred_on" => "2026-05-31"}
      )

      open_group!(conn, %{
        "group_id" => "group-exp",
        "occurred_on" => "2027-05-01",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      apply_operation!(
        conn,
        apply_credit_operation(%{
          "group_id" => "group-exp",
          "operation_id" => "op-credit-exp",
          "occurred_on" => "2027-05-15",
          "amount_cents" => 2_000
        })
      )

      assert guest_credit(conn, "guest-22")["available_cents"] == 3_500
      assert ledger(conn)["credit_liability_cents"] == 5_500

      # Refundable cancellation after the funding lot expired on 2027-06-01.
      result =
        apply_operation!(
          conn,
          cancel_operation(%{
            "group_id" => "group-exp",
            "operation_id" => "op-cancel-exp",
            "occurred_on" => "2027-06-10"
          })
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 3_500

      assert [%{"remaining_cents" => remaining, "expires_on" => "2027-06-01"}] = credit["lots"]
      assert remaining == 3_500

      # The restored 2000 reduced the liability instead of returning.
      assert ledger(conn)["credit_liability_cents"] == 3_500
    end
  end

  describe "credit and ledger reads" do
    test "lists available lots ordered by expiry then source_operation_id", %{conn: conn} do
      issue_credit!(conn, "group-src-z", "op-cancel-z", 1_000)
      issue_credit!(conn, "group-src-b", "op-cancel-b", 2_000)

      credit = guest_credit(conn, "guest-22")

      # All lots were issued from cancellations on 2026-11-26 and expire
      # 2027-11-27, so they are ordered by source_operation_id.
      assert Enum.map(credit["lots"], & &1["source_operation_id"]) == [
               "op-cancel-b",
               "op-cancel-z"
             ]

      assert credit["available_cents"] == 3_300
    end

    test "omits expired and exhausted lots", %{conn: conn} do
      issue_credit!(conn, "group-src", "op-cancel-src", 5_000)

      open_group!(conn, %{
        "group_id" => "group-81",
        "occurred_on" => "2026-12-01",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      # Exhaust the lot.
      apply_operation!(
        conn,
        apply_credit_operation(%{"amount_cents" => 5_500})
      )

      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "reports expiry as of the on query parameter", %{conn: conn} do
      issue_credit!(conn, "group-src", "op-cancel-src", 5_000)

      # The lot is available through 2027-11-26 and expires on 2027-11-27.
      assert guest_credit(conn, "guest-22", "2027-11-26")["available_cents"] == 5_500
      assert guest_credit(conn, "guest-22", "2027-11-27")["available_cents"] == 0

      assert ledger(conn, "2027-11-26")["credit_liability_cents"] == 5_500
      assert ledger(conn, "2027-11-27")["credit_liability_cents"] == 0
    end

    test "returns an empty wallet for an unknown guest", %{conn: conn} do
      assert guest_credit(conn, "guest-nobody") == %{
               "guest_id" => "guest-nobody",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "rejects an unparseable on parameter", %{conn: conn} do
      conn = get(conn, "/api/v1/guests/guest-22/credit?on=soon")
      assert %{"error" => %{"code" => "invalid_date"}} = json_response(conn, 422)

      conn = get(conn, "/api/v1/ledger?on=soon")
      assert %{"error" => %{"code" => "invalid_date"}} = json_response(conn, 422)
    end
  end
end
