defmodule GroupStayWeb.PaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  @deposit_a 9_000

  describe "reduce_cash_payment" do
    test "removes held allocations in reverse fill order and reopens the deposit" do
      open_default_group("group-reduce")
      run_and_get_results([pay_operation("group-reduce", 19_500, %{"operation_id" => "op-pay"})])

      results =
        run_and_get_results([
          reduce_cash_operation("op-pay", 4_000, %{"operation_id" => "op-reduce-one"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-reduce-one",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-reduce",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 4_000,
               "revision" => 3
             }

      # The reduction comes off room-b first (reverse fill order).
      [a, b] = fetch_group("group-reduce")["rooms"]
      assert a["cash_paid_cents"] == @deposit_a
      assert b["cash_paid_cents"] == 6_500

      statement = fetch_payment("op-pay")
      assert statement["held_cents"] == 15_500
      assert statement["reduced_cents"] == 4_000
      assert statement["recorded_cents"] == 19_500
    end

    test "successive reductions compose against the remaining held cash" do
      open_default_group("group-compose")
      run_and_get_results([pay_operation("group-compose", 10_000, %{"operation_id" => "op-pay"})])

      results =
        run_and_get_results([
          reduce_cash_operation("op-pay", 2_000, %{"operation_id" => "op-red-1"}),
          reduce_cash_operation("op-pay", 8_000, %{"operation_id" => "op-red-2"})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]

      assert fetch_group("group-compose")["outstanding_deposit_cents"] == 19_500
      assert fetch_payment("op-pay")["held_cents"] == 0
      assert fetch_ledger()["cash_reduced_cents"] == 10_000
    end

    test "uses the documented rejection codes" do
      open_default_group("group-codes")

      assert hd(
               run_and_get_results([
                 reduce_cash_operation("never-seen", 100, %{"operation_id" => "op-no-record"})
               ])
             )["code"] == "operation_not_found"

      run_and_get_results([
        pay_operation("group-codes", 5_000, %{"operation_id" => "op-pay-codes"})
      ])

      for {name, amount} <- [zero: 0, negative: -100] do
        results =
          run_and_get_results([
            reduce_cash_operation("op-pay-codes", amount, %{
              "operation_id" => "op-bad-amount-#{name}"
            })
          ])

        assert hd(results)["code"] == "invalid_amount", "expected invalid_amount for #{name}"
      end

      too_big =
        run_and_get_results([
          reduce_cash_operation("op-pay-codes", 5_001, %{"operation_id" => "op-too-big"})
        ])

      assert hd(too_big)["code"] == "reduction_exceeds_held_cash"
      assert fetch_group("group-codes")["revision"] == 2

      # Reduce everything; the payment can never be reduced again.
      run_and_get_results([
        reduce_cash_operation("op-pay-codes", 5_000, %{"operation_id" => "op-drain"})
      ])

      drained =
        run_and_get_results([
          reduce_cash_operation("op-pay-codes", 1, %{"operation_id" => "op-after-drain"})
        ])

      assert hd(drained)["code"] == "payment_not_reducible"

      rejected =
        post_operations([pay_operation("ghost", 100, %{"operation_id" => "op-rejected"})])

      assert hd(json_response(rejected, 200)["results"])["status"] == "rejected"

      results =
        run_and_get_results([
          reduce_cash_operation("op-rejected", 1, %{"operation_id" => "op-reduce-rejected"})
        ])

      assert hd(results)["code"] == "payment_not_reducible"
    end

    test "a non-payment operation cannot be targeted" do
      post_operations([
        open_operation(%{"operation_id" => "op-target-open", "group_id" => "group-other-target"})
      ])

      results =
        run_and_get_results([
          reduce_cash_operation("op-target-open", 100, %{"operation_id" => "op-reduce-open"})
        ])

      assert hd(results)["code"] == "payment_not_reducible"
    end

    test "retrying the original payment replays its exact original result" do
      open_default_group("group-retry-original")

      run_and_get_results([
        pay_operation("group-retry-original", 10_000, %{"operation_id" => "op-pay-ro"})
      ])

      run_and_get_results([
        reduce_cash_operation("op-pay-ro", 9_999, %{"operation_id" => "op-reduce-mostly"})
      ])

      replay =
        run_and_get_results([
          pay_operation("group-retry-original", 10_000, %{"operation_id" => "op-pay-ro"})
        ])

      assert hd(replay) == %{
               "operation_id" => "op-pay-ro",
               "status" => "applied",
               "group_id" => "group-retry-original",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }

      assert fetch_group("group-retry-original")["cash_paid_cents"] == 1
      assert fetch_ledger()["cash_held_cents"] == 1
    end

    test "is durably idempotent and supports expected_revision" do
      open_default_group("group-reduce-retry")

      run_and_get_results([
        pay_operation("group-reduce-retry", 5_000, %{"operation_id" => "op-p"})
      ])

      stale =
        run_and_get_results([
          reduce_cash_operation("op-p", 1_000, %{
            "operation_id" => "op-stale-reduce",
            "expected_revision" => 9
          })
        ])

      assert hd(stale)["code"] == "stale_revision"

      operation = reduce_cash_operation("op-p", 1_000, %{"expected_revision" => 2})

      first = run_and_get_results([operation])
      assert hd(first)["status"] == "applied"

      replay = run_and_get_results([operation])
      assert replay == first
      assert fetch_ledger()["cash_reduced_cents"] == 1_000
    end
  end

  describe "charge_back_payment" do
    test "reclassifies held and refunded portions as charged-back cash" do
      open_default_group("group-chargeback")

      run_and_get_results([
        pay_operation("group-chargeback", 15_000, %{"operation_id" => "op-cb"})
      ])

      # Room-b settles refundably with its 6_000 of the payment.
      run_and_get_results([
        cancel_rooms_operation("group-chargeback", ["room-b"], %{"occurred_on" => "2026-11-26"})
      ])

      results =
        run_and_get_results([
          charge_back_operation("op-cb", %{"operation_id" => "op-chargeback"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-cb",
               "group_id" => "group-chargeback",
               "charged_back_cents" => 15_000,
               "outstanding_deposit_cents" => @deposit_a,
               "revision" => 4
             }

      ledger = fetch_ledger()
      assert ledger["cash_charged_back_cents"] == 15_000
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_held_cents"] == 0

      [a, _b] = fetch_group("group-chargeback")["rooms"]
      assert a["cash_paid_cents"] == 0
      assert fetch_group("group-chargeback")["outstanding_deposit_cents"] == @deposit_a

      statement = fetch_payment("op-cb")
      assert statement["charged_back_cents"] == 15_000
      assert statement["refunded_cents"] == 0
      assert statement["recorded_cents"] == 15_000
    end

    test "revokes converted credit entitlement and reports the current shortfall" do
      convert_source_payment_to_credit("group-cb-source", "op-pay-src", "cancel-src")

      # Another group spends the whole lot on its deposit.
      open_spender_group("group-cb-spender")

      run_and_get_results([
        credit_operation("group-cb-spender", 21_450, %{
          "occurred_on" => "2026-12-01",
          "operation_id" => "op-spend"
        })
      ])

      assert fetch_ledger()["credit_shortfall_cents"] == 0

      results =
        run_and_get_results([
          charge_back_operation("op-pay-src", %{"operation_id" => "op-charged"})
        ])

      assert hd(results)["status"] == "applied"
      assert hd(results)["charged_back_cents"] == 19_500

      ledger = fetch_ledger()

      # The entitlement was fully applied to the active spender, so nothing
      # could be removed from the lot's balance.
      assert ledger["credit_shortfall_cents"] == 21_450
      assert ledger["credit_liability_cents"] == 21_450
      assert fetch_credit("guest-22")["available_cents"] == 0

      # Non-refundable settlement consumes the applied credit and the shortfall.
      run_and_get_results([
        cancel_operation("group-cb-spender", %{"occurred_on" => "2026-12-05"})
      ])

      assert fetch_ledger()["credit_shortfall_cents"] == 0
      assert fetch_ledger()["credit_liability_cents"] == 0
    end

    test "returning credit to a shortfalled lot extinguishes the clawback first" do
      convert_source_payment_to_credit("group-absorb-src", "op-pay-absorb", "cancel-absorb")

      open_spender_group("group-absorber")

      run_and_get_results([
        credit_operation("group-absorber", 21_450, %{
          "occurred_on" => "2026-12-01",
          "operation_id" => "op-spend-absorb"
        })
      ])

      run_and_get_results([
        charge_back_operation("op-pay-absorb", %{"operation_id" => "op-charged-absorb"})
      ])

      assert fetch_ledger()["credit_shortfall_cents"] == 21_450

      # The refundable settlement returns the credit, which absorbs the entire
      # clawback before any amount could become available again.
      results =
        run_and_get_results([
          cancel_operation("group-absorber", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert hd(results)["status"] == "applied"

      credit = fetch_credit("guest-22")
      assert credit["available_cents"] == 0
      assert credit["lots"] == []

      assert fetch_ledger()["credit_liability_cents"] == 0
      assert fetch_ledger()["credit_shortfall_cents"] == 0
    end

    test "telescoping entitlements assign each payment its own slice of a lot" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-tel",
          "group_id" => "group-telescope",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        }),
        pay_operation("group-telescope", 5_000, %{"operation_id" => "op-tel-first"}),
        pay_operation("group-telescope", 14_500, %{"operation_id" => "op-tel-second"}),
        cancel_operation("group-telescope", %{
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit",
          "operation_id" => "cancel-tel"
        })
      ])

      # bonus(5_000) = 5_500; bonus(19_500) - bonus(5_000) = 15_950.
      run_and_get_results([
        charge_back_operation("op-tel-first", %{"operation_id" => "op-claw-one"})
      ])

      assert fetch_credit("guest-22")["available_cents"] == 21_450 - 5_500

      run_and_get_results([
        charge_back_operation("op-tel-second", %{"operation_id" => "op-claw-two"})
      ])

      assert fetch_credit("guest-22")["available_cents"] == 0
      assert fetch_ledger()["credit_liability_cents"] == 0
    end

    test "charges back a payment whose group is already cancelled" do
      open_default_group("group-cancelled-cb")

      run_and_get_results([
        pay_operation("group-cancelled-cb", 19_500, %{"operation_id" => "op-pay-dead"}),
        cancel_operation("group-cancelled-cb", %{"occurred_on" => "2026-11-26"})
      ])

      assert fetch_ledger()["cash_refunded_cents"] == 19_500

      revision_before = fetch_group("group-cancelled-cb")["revision"]

      results =
        run_and_get_results([
          charge_back_operation("op-pay-dead", %{"operation_id" => "op-cb-dead"})
        ])

      assert hd(results)["status"] == "applied"
      assert hd(results)["charged_back_cents"] == 19_500
      assert hd(results)["revision"] == revision_before + 1

      assert fetch_group("group-cancelled-cb")["revision"] == revision_before + 1
      assert fetch_ledger()["cash_refunded_cents"] == 0
      assert fetch_ledger()["cash_charged_back_cents"] == 19_500
    end

    test "uses the documented rejection codes" do
      post_operations([
        open_operation(%{"operation_id" => "op-record-open", "group_id" => "group-cb-codes"})
      ])

      assert hd(
               run_and_get_results([
                 charge_back_operation("never-seen", %{"operation_id" => "op-cb-missing"})
               ])
             )["code"] == "operation_not_found"

      # A non-payment record is not chargeable.
      assert hd(
               run_and_get_results([
                 charge_back_operation("op-record-open", %{"operation_id" => "op-cb-open"})
               ])
             )["code"] == "payment_not_chargeable"

      # A rejected payment is not chargeable either.
      rejected = post_operations([pay_operation("ghost", 100, %{"operation_id" => "op-cb-rej"})])
      assert hd(json_response(rejected, 200)["results"])["status"] == "rejected"

      assert hd(
               run_and_get_results([
                 charge_back_operation("op-cb-rej", %{"operation_id" => "op-cb-rej-again"})
               ])
             )["code"] == "payment_not_chargeable"
    end

    test "a second chargeback of the same payment is rejected" do
      open_default_group("group-twice-cb")

      run_and_get_results([
        pay_operation("group-twice-cb", 1_000, %{"operation_id" => "op-pay-2x"})
      ])

      assert hd(
               run_and_get_results([
                 charge_back_operation("op-pay-2x", %{"operation_id" => "op-cbx-1"})
               ])
             )["status"] == "applied"

      second =
        run_and_get_results([charge_back_operation("op-pay-2x", %{"operation_id" => "op-cbx-2"})])

      assert hd(second)["code"] == "payment_not_chargeable"
      assert fetch_ledger()["cash_charged_back_cents"] == 1_000
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition and they sum to the recorded amount" do
      open_default_group("group-statement")

      run_and_get_results([
        pay_operation("group-statement", 19_500, %{"operation_id" => "op-state"}),
        reduce_cash_operation("op-state", 1_000, %{"operation_id" => "op-state-reduce"})
      ])

      assert fetch_payment("op-state") == %{
               "payment_operation_id" => "op-state",
               "original_group_id" => "group-statement",
               "recorded_cents" => 19_500,
               "held_cents" => 18_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             }
    end

    test "dispositions agree with the group view across a full lifecycle" do
      open_default_group("group-lifecycle")

      run_and_get_results([
        pay_operation("group-lifecycle", 15_000, %{"operation_id" => "op-life"}),
        cancel_rooms_operation("group-lifecycle", ["room-b"], %{"occurred_on" => "2026-11-26"}),
        reduce_cash_operation("op-life", 1_500, %{"operation_id" => "op-life-reduce"}),
        charge_back_operation("op-life", %{"operation_id" => "op-life-cb"})
      ])

      statement = fetch_payment("op-life")

      # 15_000 recorded: 1_500 reduced, room-b's 4_500 refunded at settlement,
      # and the remaining 9_000 held on room-a charged back.
      assert statement["refunded_cents"] == 0
      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 1_500
      assert statement["charged_back_cents"] == 13_500

      dispositions =
        statement
        |> Map.drop(["payment_operation_id", "original_group_id", "recorded_cents"])
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      assert dispositions == statement["recorded_cents"]

      assert fetch_group("group-lifecycle")["outstanding_deposit_cents"] == @deposit_a
    end

    test "all seven monetary fields are always present, including zeros" do
      open_default_group("group-fresh-payment")

      run_and_get_results([
        pay_operation("group-fresh-payment", 1_234, %{"operation_id" => "op-z"})
      ])

      statement = fetch_payment("op-z")

      assert statement |> Map.keys() |> Enum.sort() == [
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

      assert %{
               "held_cents" => 1_234,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             } = statement
    end

    test "reading a statement never changes state" do
      open_default_group("group-readonly")
      run_and_get_results([pay_operation("group-readonly", 1_000, %{"operation_id" => "op-ro"})])

      before = fetch_group("group-readonly")

      fetch_payment("op-ro")
      fetch_payment("op-ro")

      assert fetch_group("group-readonly") == before
    end

    test "returns 404 operation_not_found without a durable record" do
      conn = build_conn() |> get("/api/v1/payments/unknown-payment")

      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 payment_not_reconcilable for non-payment records" do
      post_operations([
        open_operation(%{"operation_id" => "op-not-a-payment", "group_id" => "group-nr"})
      ])

      conn = build_conn() |> get("/api/v1/payments/op-not-a-payment")

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      rejected = post_operations([pay_operation("ghost", 100, %{"operation_id" => "op-rej-pay"})])
      assert hd(json_response(rejected, 200)["results"])["status"] == "rejected"

      conn = build_conn() |> get("/api/v1/payments/op-rej-pay")

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end

  # Opens an active group whose 24_000 deposit can absorb a full credit lot.
  defp open_spender_group(group_id) do
    post_operations([
      open_operation(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "rooms" => [%{"room_id" => "room-suite", "nightly_rate_cents" => 40_000}]
      })
    ])

    :ok
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end

  # Funds a source group with 19_500 of cash and converts it into a 21_450
  # hotel-credit lot through a refundable hotel-credit cancellation.
  defp convert_source_payment_to_credit(group_id, payment_operation_id, cancel_operation_id) do
    post_operations([
      open_operation(%{
        "operation_id" => "op-open-#{payment_operation_id}",
        "group_id" => group_id,
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 32_500}]
      }),
      pay_operation(group_id, 19_500, %{"operation_id" => payment_operation_id}),
      cancel_operation(group_id, %{
        "occurred_on" => "2026-11-01",
        "refund_method" => "hotel_credit",
        "operation_id" => cancel_operation_id
      })
    ])

    :ok
  end
end
