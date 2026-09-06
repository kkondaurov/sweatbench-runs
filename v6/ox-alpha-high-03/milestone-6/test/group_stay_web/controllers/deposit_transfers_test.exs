defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  describe "transfer_deposit" do
    test "moves held funding between two active groups and bumps both revisions" do
      open_default_group("group-ta")
      open_destination("group-tb")

      run_and_get_results([pay_operation("group-ta", 12_000, %{"operation_id" => "op-pay-ta"})])

      results =
        run_and_get_results([
          transfer_operation("group-ta", "group-tb", 5_000, %{"operation_id" => "op-tr"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-tr",
               "status" => "applied",
               "source_group_id" => "group-ta",
               "destination_group_id" => "group-tb",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 12_500,
               "destination_outstanding_deposit_cents" => 14_500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      assert fetch_group("group-ta")["revision"] == 3
      assert fetch_group("group-tb")["revision"] == 2

      # A transfer changes no ledger total.
      assert fetch_ledger()["cash_held_cents"] == 12_000
    end

    test "draws from the source in reverse allocation order and fills the destination in room order" do
      open_default_group("group-order-a")

      open_destination("group-order-b", %{
        "rooms" => [
          %{"room_id" => "room-x", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-y", "nightly_rate_cents" => 10_000}
        ]
      })

      # Funds room-a (9_000) fully and then room-b with 3_000.
      run_and_get_results([
        pay_operation("group-order-a", 12_000, %{"operation_id" => "op-pay-order"})
      ])

      results =
        run_and_get_results([
          transfer_operation("group-order-a", "group-order-b", 9_500, %{
            "operation_id" => "op-tr-order"
          })
        ])

      assert hd(results)["status"] == "applied"

      # The draw takes room-b's 3_000 first, then 6_500 of room-a. The
      # destination's first room absorbs one full unit before the next opens.
      [x, y] = fetch_group("group-order-b")["rooms"]
      assert x["room_id"] == "room-x"
      assert x["cash_paid_cents"] == 6_000
      assert y["cash_paid_cents"] == 3_500

      [a, b] = fetch_group("group-order-a")["rooms"]
      assert a["cash_paid_cents"] == 2_500
      assert b["cash_paid_cents"] == 0
      assert fetch_group("group-order-a")["outstanding_deposit_cents"] == 17_000
      assert fetch_group("group-order-b")["outstanding_deposit_cents"] == 2_500
    end

    test "transferred credit keeps its lot, stays applied, and earns no second bonus" do
      issue_credit_lot("group-lot-src", "op-pay-lot", "cancel-lot")
      open_default_group("group-ca")
      open_destination("group-cb")

      run_and_get_results([
        credit_operation("group-ca", 10_000, %{"occurred_on" => "2026-12-01"})
      ])

      liability_before = fetch_ledger()["credit_liability_cents"]
      available_before = fetch_credit("guest-22")["available_cents"]

      results =
        run_and_get_results([
          transfer_operation("group-ca", "group-cb", 4_000, %{"operation_id" => "op-tr-credit"})
        ])

      assert hd(results)["status"] == "applied"

      assert fetch_group("group-ca")["credit_paid_cents"] == 6_000
      assert fetch_group("group-cb")["credit_paid_cents"] == 4_000
      assert fetch_group("group-ca")["cash_paid_cents"] == 0
      assert fetch_group("group-cb")["cash_paid_cents"] == 0

      # No bonus is computed and the lot balance is untouched; applying or
      # moving the credit does not change the liability either.
      assert fetch_credit("guest-22")["available_cents"] == available_before
      assert fetch_ledger()["credit_liability_cents"] == liability_before
    end

    test "transferred cash settles under the destination group's cancellation policy" do
      open_default_group("group-pol-a")

      # Booked on 2027-01-10, so the destination uses the flex-30 window.
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-pol-b",
          "group_id" => "group-pol-b",
          "occurred_on" => "2027-01-10",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })
      ])

      run_and_get_results([
        pay_operation("group-pol-a", 5_000, %{"operation_id" => "op-pay-pol"})
      ])

      run_and_get_results([
        transfer_operation("group-pol-a", "group-pol-b", 5_000, %{"operation_id" => "op-tr-pol"})
      ])

      # 22 days before arrival: refundable under the source's flex-14 window,
      # but not under the destination's flex-30 window.
      results =
        run_and_get_results([
          cancel_operation("group-pol-b", %{"occurred_on" => "2027-05-10"})
        ])

      assert hd(results)["status"] == "applied"
      assert hd(results)["retained_cents"] == 5_000
      assert hd(results)["refunded_cents"] == 0
      assert fetch_ledger()["cash_retained_cents"] == 5_000
      assert fetch_ledger()["cash_refunded_cents"] == 0
    end
  end

  describe "transfer_deposit rejections" do
    test "rejects transfers within one group or across guests as invalid_transfer" do
      open_default_group("group-inv")

      same =
        run_and_get_results([
          transfer_operation("group-inv", "group-inv", 100, %{"operation_id" => "op-same"})
        ])

      assert hd(same)["code"] == "invalid_transfer"

      post_operations([
        open_operation(%{
          "operation_id" => "op-open-other-guest",
          "group_id" => "group-other-guest",
          "guest_id" => "guest-99"
        })
      ])

      cross =
        run_and_get_results([
          transfer_operation("group-inv", "group-other-guest", 100, %{
            "operation_id" => "op-cross"
          })
        ])

      assert hd(cross)["code"] == "invalid_transfer"
      assert fetch_group("group-inv")["revision"] == 1
    end

    test "resolves source existence, then destination existence, with that group_id" do
      open_default_group("group-exists")

      missing_source =
        run_and_get_results([
          transfer_operation("group-nowhere", "group-exists", 100, %{"operation_id" => "op-ms"})
        ])

      assert hd(missing_source) == %{
               "operation_id" => "op-ms",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-nowhere"
             }

      missing_destination =
        run_and_get_results([
          transfer_operation("group-exists", "group-nowhere", 100, %{"operation_id" => "op-md"})
        ])

      assert hd(missing_destination) == %{
               "operation_id" => "op-md",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-nowhere"
             }
    end

    test "reports group_not_active for an inactive source or destination with that group_id" do
      open_default_group("group-dead")
      open_destination("group-live")

      run_and_get_results([
        cancel_operation("group-dead", %{"occurred_on" => "2026-11-26"})
      ])

      inactive_source =
        run_and_get_results([
          transfer_operation("group-dead", "group-live", 100, %{"operation_id" => "op-is"})
        ])

      assert hd(inactive_source) == %{
               "operation_id" => "op-is",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-dead"
             }

      inactive_destination =
        run_and_get_results([
          transfer_operation("group-live", "group-dead", 100, %{"operation_id" => "op-id"})
        ])

      assert hd(inactive_destination)["code"] == "group_not_active"
      assert hd(inactive_destination)["group_id"] == "group-dead"
    end

    test "uses invalid_amount for non-positive amounts" do
      open_default_group("group-amt-a")
      open_destination("group-amt-b")

      for {name, amount} <- [zero: 0, negative: -500] do
        results =
          run_and_get_results([
            transfer_operation("group-amt-a", "group-amt-b", amount, %{
              "operation_id" => "op-amt-#{name}"
            })
          ])

        assert hd(results)["code"] == "invalid_amount", "expected invalid_amount for #{name}"
      end
    end

    test "rejects amounts beyond held funding or outstanding deposit" do
      open_default_group("group-cap-a")

      # The destination's deposit due is only 3_000.
      open_destination("group-cap-b", %{
        "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 5_000}]
      })

      run_and_get_results([
        pay_operation("group-cap-a", 8_000, %{"operation_id" => "op-pay-cap"})
      ])

      exceeds_held =
        run_and_get_results([
          transfer_operation("group-cap-a", "group-cap-b", 8_001, %{"operation_id" => "op-held"})
        ])

      assert hd(exceeds_held)["code"] == "transfer_exceeds_held_funding"

      # Within the source's held funding but beyond the destination's
      # outstanding deposit.
      exceeds_outstanding =
        run_and_get_results([
          transfer_operation("group-cap-a", "group-cap-b", 3_001, %{"operation_id" => "op-out"})
        ])

      assert hd(exceeds_outstanding)["code"] == "transfer_exceeds_outstanding"

      assert fetch_group("group-cap-a")["revision"] == 2
      assert fetch_group("group-cap-b")["revision"] == 1
      assert fetch_group("group-cap-a")["cash_paid_cents"] == 8_000
    end

    test "checks both revision guards after existence and before the transfer rules" do
      open_default_group("group-rev-a")
      open_destination("group-rev-b")

      run_and_get_results([
        pay_operation("group-rev-a", 5_000, %{"operation_id" => "op-pay-rev"})
      ])

      stale_source =
        run_and_get_results([
          transfer_operation("group-rev-a", "group-rev-b", 1_000, %{
            "operation_id" => "op-stale-src",
            "expected_revision" => 1
          })
        ])

      assert hd(stale_source) == %{
               "operation_id" => "op-stale-src",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-rev-a",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      stale_destination =
        run_and_get_results([
          transfer_operation("group-rev-a", "group-rev-b", 1_000, %{
            "operation_id" => "op-stale-dst",
            "expected_revision" => 2,
            "destination_expected_revision" => 7
          })
        ])

      assert hd(stale_destination) == %{
               "operation_id" => "op-stale-dst",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-rev-b",
               "expected_revision" => 7,
               "actual_revision" => 1
             }

      # The guard precedes domain rules: a stale source wins over an
      # invalid amount.
      guard_first =
        run_and_get_results([
          transfer_operation("group-rev-a", "group-rev-b", 0, %{
            "operation_id" => "op-guard-first",
            "expected_revision" => 1
          })
        ])

      assert hd(guard_first)["code"] == "stale_revision"
      assert fetch_group("group-rev-a")["revision"] == 2
      assert fetch_group("group-rev-b")["revision"] == 1
    end
  end

  describe "transfer idempotency" do
    test "retries replay the stored result and conflicts on a different payload" do
      open_default_group("group-idem-a")
      open_destination("group-idem-b")

      run_and_get_results([pay_operation("group-idem-a", 6_000, %{"operation_id" => "op-pay-i"})])

      operation =
        transfer_operation("group-idem-a", "group-idem-b", 2_500, %{"operation_id" => "op-tr-i"})

      first = run_and_get_results([operation])
      assert hd(first)["status"] == "applied"

      replay = run_and_get_results([operation])
      assert replay == first
      assert fetch_group("group-idem-b")["cash_paid_cents"] == 2_500

      conflict =
        run_and_get_results([
          transfer_operation("group-idem-a", "group-idem-b", 9_999, %{"operation_id" => "op-tr-i"})
        ])

      assert hd(conflict)["code"] == "operation_id_conflict"
      assert fetch_group("group-idem-b")["cash_paid_cents"] == 2_500
      assert fetch_ledger()["cash_held_cents"] == 6_000
    end
  end

  describe "payment statement evolution" do
    test "adds held_by_group only once funding has participated in a transfer" do
      open_default_group("group-hb-a")
      open_destination("group-hb-b")

      run_and_get_results([pay_operation("group-hb-a", 12_000, %{"operation_id" => "op-pay-hb"})])

      before = fetch_payment("op-pay-hb")
      refute Map.has_key?(before, "held_by_group")

      run_and_get_results([
        transfer_operation("group-hb-a", "group-hb-b", 5_000, %{"operation_id" => "op-tr-hb"})
      ])

      statement = fetch_payment("op-pay-hb")

      assert statement["held_by_group"] == [
               %{"group_id" => "group-hb-a", "amount_cents" => 7_000},
               %{"group_id" => "group-hb-b", "amount_cents" => 5_000}
             ]

      assert statement["held_cents"] == 12_000

      assert statement["held_by_group"] |> Enum.map(& &1["amount_cents"]) |> Enum.sum() ==
               statement["held_cents"]

      # After none remains held the list is empty but still present.
      run_and_get_results([charge_back_operation("op-pay-hb", %{"operation_id" => "op-cb-hb"})])

      statement = fetch_payment("op-pay-hb")
      assert statement["held_cents"] == 0
      assert statement["held_by_group"] == []
    end

    test "reductions follow a payment's allocations wherever they now fund rooms" do
      open_default_group("group-red-a")
      open_destination("group-red-b")

      run_and_get_results([pay_operation("group-red-a", 12_000, %{"operation_id" => "op-pay-r"})])

      run_and_get_results([
        transfer_operation("group-red-a", "group-red-b", 5_000, %{"operation_id" => "op-tr-r"})
      ])

      revisions_before = group_revisions(["group-red-a", "group-red-b"])

      results =
        run_and_get_results([
          reduce_cash_operation("op-pay-r", 4_000, %{"operation_id" => "op-red-r"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-red-r",
               "status" => "applied",
               "payment_operation_id" => "op-pay-r",
               "group_id" => "group-red-a",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 12_500,
               "revision" => 4
             }

      # Both the addressed payment group and the other funded group advance.
      assert fetch_group("group-red-a")["revision"] ==
               revisions_before["group-red-a"] + 1

      assert fetch_group("group-red-b")["revision"] ==
               revisions_before["group-red-b"] + 1

      assert fetch_payment("op-pay-r")["held_by_group"] == [
               %{"group_id" => "group-red-a", "amount_cents" => 7_000},
               %{"group_id" => "group-red-b", "amount_cents" => 1_000}
             ]

      assert fetch_ledger()["cash_reduced_cents"] == 4_000
    end

    test "chargebacks remove held allocations across groups and bump each affected revision" do
      open_default_group("group-cb-a")
      open_destination("group-cb-b")

      run_and_get_results([pay_operation("group-cb-a", 12_000, %{"operation_id" => "op-pay-c"})])

      run_and_get_results([
        transfer_operation("group-cb-a", "group-cb-b", 5_000, %{"operation_id" => "op-tr-c"})
      ])

      revisions_before = group_revisions(["group-cb-a", "group-cb-b"])

      results =
        run_and_get_results([
          charge_back_operation("op-pay-c", %{"operation_id" => "op-cb-c"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-cb-c",
               "status" => "applied",
               "payment_operation_id" => "op-pay-c",
               "group_id" => "group-cb-a",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      assert fetch_group("group-cb-a")["revision"] ==
               revisions_before["group-cb-a"] + 1

      assert fetch_group("group-cb-b")["revision"] ==
               revisions_before["group-cb-b"] + 1

      assert fetch_group("group-cb-a")["cash_paid_cents"] == 0
      assert fetch_group("group-cb-b")["cash_paid_cents"] == 0
      assert fetch_ledger()["cash_charged_back_cents"] == 12_000
      assert fetch_ledger()["cash_held_cents"] == 0
    end
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_revisions(group_ids) do
    Map.new(group_ids, fn group_id -> {group_id, fetch_group(group_id)["revision"]} end)
  end

  defp open_destination(group_id, overrides \\ %{}) do
    post_operations([
      open_operation(
        Map.merge(%{"operation_id" => "op-open-#{group_id}", "group_id" => group_id}, overrides)
      )
    ])
  end

  # Funds a source group with 19_500 of cash and converts it into a 21_450
  # hotel-credit lot through a refundable hotel-credit cancellation.
  defp issue_credit_lot(group_id, payment_operation_id, cancel_operation_id) do
    post_operations([
      open_operation(%{
        "operation_id" => "op-open-#{payment_operation_id}",
        "group_id" => group_id,
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04",
        "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 32_500}]
      }),
      pay_operation(group_id, 19_500, %{"operation_id" => payment_operation_id}),
      cancel_operation(group_id, %{
        "occurred_on" => "2026-11-01",
        "refund_method" => "hotel_credit",
        "operation_id" => cancel_operation_id
      })
    ])
  end
end
