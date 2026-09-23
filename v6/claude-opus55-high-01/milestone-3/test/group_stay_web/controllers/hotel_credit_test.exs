defmodule GroupStayWeb.HotelCreditTest do
  use GroupStayWeb.ConnCase

  # Groups here are booked in 2027 under flex-30. The default rooms need a 19_500 cent deposit.

  # Opens a flexible group for `guest_id` booked on 2027-01-05, arriving 2027-06-10 (refundable
  # until 2027-05-11), and applies `cash` to it.
  defp open_paid_group(group_id, guest_id, cash, overrides \\ %{}) do
    results =
      submit([
        open_group_op(
          Map.merge(
            %{
              "operation_id" => "open-#{group_id}",
              "occurred_on" => "2027-01-05",
              "group_id" => group_id,
              "guest_id" => guest_id,
              "arrival_on" => "2027-06-10",
              "departure_on" => "2027-06-13"
            },
            overrides
          )
        ),
        payment_op(%{
          "operation_id" => "pay-#{group_id}",
          "occurred_on" => "2027-01-06",
          "group_id" => group_id,
          "amount_cents" => cash
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  # Issues a credit lot of `cash` plus the bonus to `guest_id` from a cancellation on `on`.
  defp issue_credit(guest_id, cash, cancel_id, on) do
    group_id = "credit-source-#{cancel_id}"
    open_paid_group(group_id, guest_id, cash)

    assert %{"status" => "applied"} =
             submit_one(
               cancel_op(%{
                 "operation_id" => cancel_id,
                 "occurred_on" => on,
                 "group_id" => group_id,
                 "refund_method" => "hotel_credit"
               })
             )
  end

  # Opens an unpaid flexible group for `guest_id` to spend credit on. Refundable until
  # 2027-08-11.
  defp open_spending_group(group_id \\ "stay-2", guest_id \\ "guest-22", overrides \\ %{}) do
    assert %{"status" => "applied"} =
             submit_one(
               open_group_op(
                 Map.merge(
                   %{
                     "operation_id" => "open-#{group_id}",
                     "occurred_on" => "2027-02-01",
                     "group_id" => group_id,
                     "guest_id" => guest_id,
                     "arrival_on" => "2027-09-10",
                     "departure_on" => "2027-09-13"
                   },
                   overrides
                 )
               )
             )
  end

  defp lots(guest_id, on) do
    guest_id
    |> get_guest_credit(%{"on" => on})
    |> Map.fetch!("lots")
    |> Enum.map(&{&1["source_operation_id"], &1["remaining_cents"], &1["expires_on"]})
  end

  describe "cancel_group with hotel_credit" do
    test "converts refundable cash into a credit lot worth 110%" do
      open_paid_group("group-81", "guest-22", 5000)

      assert submit_one(
               cancel_op(%{
                 "operation_id" => "cancel-17",
                 "occurred_on" => "2027-05-01",
                 "refund_method" => "hotel_credit"
               })
             ) == %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             }

      assert get_guest_credit("guest-22", %{"on" => "2027-05-01"}) == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5500,
                   "expires_on" => "2028-05-01"
                 }
               ]
             }

      assert get_ledger(%{"on" => "2027-05-01"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }

      group = get_group("group-81")
      assert group["status"] == "cancelled"
      assert group["cash_paid_cents"] == 5000
      assert group["credit_paid_cents"] == 0
    end

    test "rounds the 10% bonus to the nearest cent with half-cents upward" do
      for {cash, issued} <- [{1004, 1104}, {1005, 1106}, {1006, 1107}, {1, 1}, {5, 6}] do
        group_id = "g-#{cash}"
        open_paid_group(group_id, "guest-#{cash}", cash)

        assert %{"credit_issued_cents" => ^issued} =
                 submit_one(
                   cancel_op(%{
                     "group_id" => group_id,
                     "occurred_on" => "2027-02-01",
                     "refund_method" => "hotel_credit"
                   })
                 )
      end
    end

    test "is usable through 365 days after cancellation and expires the following day" do
      issue_credit("guest-22", 5000, "cancel-17", "2027-03-01")

      # 2028 is a leap year: the 365th day after 2027-03-01 is 2028-02-29.
      assert [{"cancel-17", 5500, "2028-03-01"}] = lots("guest-22", "2028-02-29")
      assert lots("guest-22", "2028-03-01") == []
      assert get_guest_credit("guest-22", %{"on" => "2028-03-01"})["available_cents"] == 0

      assert get_ledger(%{"on" => "2028-02-29"})["credit_liability_cents"] == 5500
      assert get_ledger(%{"on" => "2028-03-01"})["credit_liability_cents"] == 0
    end

    test "issues nothing when no cash was paid" do
      submit_one(
        open_group_op(%{
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        })
      )

      assert %{"status" => "applied", "credit_issued_cents" => 0, "refunded_cents" => 0} =
               submit_one(
                 cancel_op(%{"occurred_on" => "2027-02-01", "refund_method" => "hotel_credit"})
               )

      assert db_snapshot()["credit_lots"] == []
      assert get_ledger()["cash_converted_to_credit_cents"] == 0
    end

    test "an explicit cash refund method behaves like omitting it" do
      open_paid_group("group-81", "guest-22", 5000)

      assert %{"refunded_cents" => 5000, "retained_cents" => 0, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"occurred_on" => "2027-05-11", "refund_method" => "cash"}))

      assert get_ledger()["cash_refunded_cents"] == 5000
      assert db_snapshot()["credit_lots"] == []
    end

    test "rejects hotel credit for a non-refundable cancellation and leaves the group active" do
      open_paid_group("late", "guest-22", 5000)

      open_paid_group("prepaid", "guest-22", 97_500, %{"rate_plan" => "advance_purchase"})

      open_paid_group("advance-deposit", "guest-22", 1, %{"rate_plan" => "advance_purchase"})
      before = db_snapshot()

      for {group_id, on} <- [
            {"late", "2027-05-12"},
            {"prepaid", "2027-01-07"},
            {"advance-deposit", "2027-01-07"}
          ] do
        assert submit_one(
                 cancel_op(%{
                   "operation_id" => "op-cancel-#{group_id}",
                   "group_id" => group_id,
                   "occurred_on" => on,
                   "refund_method" => "hotel_credit"
                 })
               ) == %{
                 "operation_id" => "op-cancel-#{group_id}",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               }
      end

      assert db_snapshot() == before
      assert %{"status" => "active", "revision" => 2} = get_group("late")

      # The group can still be cancelled with the default method.
      assert %{"status" => "applied", "retained_cents" => 5000, "revision" => 3} =
               submit_one(cancel_op(%{"group_id" => "late", "occurred_on" => "2027-05-12"}))
    end

    test "rejects unknown refund methods as invalid operations" do
      open_paid_group("group-81", "guest-22", 5000)
      before = db_snapshot()

      for method <- ["credit", "HOTEL_CREDIT", "", 1, %{"method" => "cash"}] do
        assert %{"status" => "rejected", "code" => "invalid_operation"} =
                 submit_one(cancel_op(%{"refund_method" => method})),
               "expected invalid_operation for #{inspect(method)}"
      end

      assert db_snapshot() == before
    end

    test "checks the revision before the refund method" do
      open_paid_group("group-81", "guest-22", 5000)

      assert %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2} =
               submit_one(
                 cancel_op(%{
                   "occurred_on" => "2027-05-12",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 1
                 })
               )

      assert %{"code" => "refund_method_not_available"} =
               submit_one(
                 cancel_op(%{
                   "occurred_on" => "2027-05-12",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 })
               )
    end

    test "an inactive group is reported before the refund method" do
      open_paid_group("group-81", "guest-22", 5000)
      submit_one(cancel_op(%{"occurred_on" => "2027-05-12"}))

      assert %{"code" => "group_not_active"} =
               submit_one(
                 cancel_op(%{"occurred_on" => "2027-05-12", "refund_method" => "hotel_credit"})
               )
    end
  end

  describe "apply_hotel_credit" do
    setup do
      issue_credit("guest-22", 5000, "cancel-17", "2027-01-20")
      open_spending_group()
      :ok
    end

    test "applies credit to the outstanding deposit without changing the liability" do
      assert submit_one(
               apply_credit_op(%{
                 "operation_id" => "op-apply",
                 "occurred_on" => "2027-02-02",
                 "group_id" => "stay-2",
                 "amount_cents" => 3000
               })
             ) == %{
               "operation_id" => "op-apply",
               "status" => "applied",
               "group_id" => "stay-2",
               "amount_cents" => 3000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 2
             }

      assert %{
               "deposit_paid_cents" => 3000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 3000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 2
             } = get_group("stay-2")

      assert lots("guest-22", "2027-02-02") == [{"cancel-17", 2500, "2028-01-21"}]
      assert get_guest_credit("guest-22", %{"on" => "2027-02-02"})["available_cents"] == 2500

      assert %{"credit_liability_cents" => 5500, "cash_held_cents" => 0} =
               get_ledger(%{"on" => "2027-02-02"})
    end

    test "combines with cash payments against the same deposit" do
      [credit, cash, too_much] =
        submit([
          apply_credit_op(%{"group_id" => "stay-2", "occurred_on" => "2027-02-02"}),
          payment_op(%{
            "group_id" => "stay-2",
            "occurred_on" => "2027-02-02",
            "amount_cents" => 18_500
          }),
          apply_credit_op(%{
            "group_id" => "stay-2",
            "occurred_on" => "2027-02-02",
            "amount_cents" => 1
          })
        ])

      assert %{"status" => "applied", "outstanding_deposit_cents" => 18_500} = credit
      assert %{"status" => "applied", "outstanding_deposit_cents" => 0} = cash
      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = too_much

      assert %{
               "deposit_paid_cents" => 19_500,
               "cash_paid_cents" => 18_500,
               "credit_paid_cents" => 1000,
               "outstanding_deposit_cents" => 0
             } = get_group("stay-2")

      assert get_ledger(%{"on" => "2027-02-02"})["cash_held_cents"] == 18_500
    end

    test "rejects more credit than the guest has without changing anything" do
      before = db_snapshot()

      assert submit_one(
               apply_credit_op(%{
                 "operation_id" => "op-credit",
                 "group_id" => "stay-2",
                 "occurred_on" => "2027-02-02",
                 "amount_cents" => 5501
               })
             ) == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      assert db_snapshot() == before
      assert get_group("stay-2")["revision"] == 1

      assert %{"status" => "applied", "outstanding_deposit_cents" => 14_000} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-2",
                   "occurred_on" => "2027-02-02",
                   "amount_cents" => 5500
                 })
               )
    end

    test "only uses the credit of the group's guest" do
      open_spending_group("other-stay", "guest-99")

      assert %{"code" => "insufficient_credit"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "other-stay",
                   "occurred_on" => "2027-02-02",
                   "amount_cents" => 1
                 })
               )
    end

    test "evaluates expiry on the operation date" do
      open_spending_group("stay-3", "guest-22", %{
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-02"
      })

      assert %{"code" => "insufficient_credit"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-3",
                   "occurred_on" => "2028-01-21",
                   "amount_cents" => 1
                 })
               )

      assert %{"status" => "applied"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-3",
                   "occurred_on" => "2028-01-20",
                   "amount_cents" => 1
                 })
               )
    end

    test "uses the existing payment validation errors" do
      before = db_snapshot()

      for amount <- [0, -5, 10.5, "100", nil] do
        expected = if amount == nil, do: "invalid_operation", else: "invalid_amount"

        assert %{"status" => "rejected", "code" => ^expected} =
                 submit_one(apply_credit_op(%{"group_id" => "stay-2", "amount_cents" => amount})),
               "expected #{expected} for #{inspect(amount)}"
      end

      assert %{"code" => "payment_exceeds_outstanding"} =
               submit_one(apply_credit_op(%{"group_id" => "stay-2", "amount_cents" => 19_501}))

      assert %{"code" => "group_not_found"} =
               submit_one(apply_credit_op(%{"group_id" => "missing", "amount_cents" => 1}))

      assert %{"code" => "invalid_operation"} =
               submit_one(Map.delete(apply_credit_op(), "group_id"))

      assert db_snapshot() == before

      submit_one(cancel_op(%{"group_id" => "stay-2", "occurred_on" => "2027-02-02"}))

      assert %{"code" => "group_not_active"} =
               submit_one(apply_credit_op(%{"group_id" => "stay-2", "amount_cents" => 1}))
    end

    test "follows the revision contract" do
      results =
        submit([
          apply_credit_op(%{
            "group_id" => "stay-2",
            "amount_cents" => 100,
            "expected_revision" => 1
          }),
          apply_credit_op(%{
            "group_id" => "stay-2",
            "amount_cents" => 100,
            "expected_revision" => 1
          }),
          apply_credit_op(%{
            "group_id" => "stay-2",
            "amount_cents" => 999_999,
            "expected_revision" => 1
          }),
          apply_credit_op(%{
            "group_id" => "stay-2",
            "amount_cents" => 999_999,
            "expected_revision" => 2
          }),
          apply_credit_op(%{
            "group_id" => "stay-2",
            "amount_cents" => 100,
            "expected_revision" => 2
          })
        ])

      assert [
               %{"status" => "applied", "revision" => 2},
               %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2},
               %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2},
               %{"code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "revision" => 3}
             ] = results

      # Revision is checked before credit sufficiency.
      assert %{"code" => "stale_revision"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-2",
                   "amount_cents" => 19_000,
                   "expected_revision" => 1
                 })
               )

      assert %{"code" => "insufficient_credit"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-2",
                   "amount_cents" => 5400,
                   "expected_revision" => 3
                 })
               )

      assert get_group("stay-2")["revision"] == 3
    end
  end

  describe "lot ordering" do
    setup do
      # Issued in an order different from their expiry and identifier order.
      issue_credit("guest-22", 1000, "cancel-b", "2027-02-10")
      issue_credit("guest-22", 2000, "cancel-late", "2027-03-10")
      issue_credit("guest-22", 3000, "cancel-a", "2027-02-10")
      open_spending_group()
      :ok
    end

    test "reports lots by expiry, then source operation" do
      assert lots("guest-22", "2027-03-10") == [
               {"cancel-a", 3300, "2028-02-11"},
               {"cancel-b", 1100, "2028-02-11"},
               {"cancel-late", 2200, "2028-03-10"}
             ]

      assert get_guest_credit("guest-22", %{"on" => "2027-03-10"})["available_cents"] == 6600
    end

    test "consumes lots by expiry, then source operation, omitting exhausted lots" do
      submit_one(
        apply_credit_op(%{
          "group_id" => "stay-2",
          "occurred_on" => "2027-03-10",
          "amount_cents" => 3800
        })
      )

      assert lots("guest-22", "2027-03-10") == [
               {"cancel-b", 600, "2028-02-11"},
               {"cancel-late", 2200, "2028-03-10"}
             ]

      submit_one(
        apply_credit_op(%{
          "group_id" => "stay-2",
          "occurred_on" => "2027-03-10",
          "amount_cents" => 1000
        })
      )

      assert lots("guest-22", "2027-03-10") == [{"cancel-late", 1800, "2028-03-10"}]
    end

    test "skips expired lots" do
      open_spending_group("stay-3", "guest-22", %{
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-02"
      })

      assert %{"status" => "applied"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-3",
                   "occurred_on" => "2028-02-11",
                   "amount_cents" => 2200
                 })
               )

      assert lots("guest-22", "2028-02-10") == [
               {"cancel-a", 3300, "2028-02-11"},
               {"cancel-b", 1100, "2028-02-11"}
             ]
    end
  end

  describe "cancelling a group funded by credit" do
    setup do
      issue_credit("guest-22", 5000, "cancel-17", "2027-01-20")
      open_spending_group()

      submit([
        apply_credit_op(%{
          "group_id" => "stay-2",
          "occurred_on" => "2027-02-02",
          "amount_cents" => 3000
        }),
        payment_op(%{
          "group_id" => "stay-2",
          "occurred_on" => "2027-02-02",
          "amount_cents" => 2000
        })
      ])

      :ok
    end

    test "refunds cash and restores credit to its original lot without a bonus" do
      assert %{
               "status" => "applied",
               "refunded_cents" => 2000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             } =
               submit_one(cancel_op(%{"group_id" => "stay-2", "occurred_on" => "2027-08-11"}))

      assert lots("guest-22", "2027-08-11") == [{"cancel-17", 5500, "2028-01-21"}]

      assert get_ledger(%{"on" => "2027-08-11"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "converts only the cash to a new lot with the bonus" do
      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 2200
             } =
               submit_one(
                 cancel_op(%{
                   "operation_id" => "cancel-30",
                   "group_id" => "stay-2",
                   "occurred_on" => "2027-08-11",
                   "refund_method" => "hotel_credit"
                 })
               )

      assert lots("guest-22", "2027-08-11") == [
               {"cancel-17", 5500, "2028-01-21"},
               {"cancel-30", 2200, "2028-08-11"}
             ]

      assert get_ledger(%{"on" => "2027-08-11"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 7000,
               "credit_liability_cents" => 7700
             }
    end

    test "retains cash and consumes credit when non-refundable" do
      assert %{"refunded_cents" => 0, "retained_cents" => 2000, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"group_id" => "stay-2", "occurred_on" => "2027-08-12"}))

      assert lots("guest-22", "2027-08-12") == [{"cancel-17", 2500, "2028-01-21"}]

      assert %{"cash_retained_cents" => 2000, "credit_liability_cents" => 2500} =
               get_ledger(%{"on" => "2027-08-12"})

      assert %{
               "deposit_paid_cents" => 5000,
               "cash_paid_cents" => 2000,
               "credit_paid_cents" => 3000
             } =
               get_group("stay-2")
    end

    test "applied credit does not expire while it funds an active group" do
      # The lot expires on 2028-01-21; only its unapplied part stops counting.
      assert get_ledger(%{"on" => "2028-01-21"})["credit_liability_cents"] == 3000
      assert get_guest_credit("guest-22", %{"on" => "2028-01-21"})["available_cents"] == 0
    end
  end

  describe "restoring credit whose lot has expired" do
    setup do
      issue_credit("guest-22", 5000, "cancel-17", "2027-01-20")

      open_spending_group("stay-3", "guest-22", %{
        "occurred_on" => "2027-06-01",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })

      submit_one(
        apply_credit_op(%{
          "group_id" => "stay-3",
          "occurred_on" => "2027-06-01",
          "amount_cents" => 3000
        })
      )

      :ok
    end

    test "expires the restored amount immediately and reduces the liability" do
      assert get_ledger(%{"on" => "2028-01-21"})["credit_liability_cents"] == 3000

      assert %{"refunded_cents" => 0, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"group_id" => "stay-3", "occurred_on" => "2028-02-01"}))

      assert lots("guest-22", "2028-02-01") == []
      assert get_ledger(%{"on" => "2028-02-01"})["credit_liability_cents"] == 0

      # Only the part never applied remains before the lot's own expiry.
      assert lots("guest-22", "2027-12-01") == [{"cancel-17", 2500, "2028-01-21"}]
      assert get_ledger(%{"on" => "2027-12-01"})["credit_liability_cents"] == 2500
    end

    test "treats a cancellation on the expiry date as already expired" do
      submit_one(cancel_op(%{"group_id" => "stay-3", "occurred_on" => "2028-01-21"}))

      assert get_ledger(%{"on" => "2028-01-20"})["credit_liability_cents"] == 2500
    end

    test "restores it when cancelled the day before the expiry date" do
      submit_one(cancel_op(%{"group_id" => "stay-3", "occurred_on" => "2028-01-20"}))

      assert lots("guest-22", "2028-01-20") == [{"cancel-17", 5500, "2028-01-21"}]
      assert get_ledger(%{"on" => "2028-01-21"})["credit_liability_cents"] == 0
    end
  end

  describe "credit reads" do
    test "an unknown guest has no credit" do
      assert get_guest_credit("nobody") == %{
               "guest_id" => "nobody",
               "available_cents" => 0,
               "lots" => []
             }

      assert get_guest_credit("guest/22 ü")["guest_id"] == "guest/22 ü"
    end

    test "uses the current UTC date without an on parameter" do
      today = Date.utc_today()
      issued_on = Date.add(today, -366)

      open_paid_group("old", "guest-22", 1000, %{
        "occurred_on" => Date.to_iso8601(Date.add(issued_on, -60)),
        "arrival_on" => Date.to_iso8601(Date.add(issued_on, 60)),
        "departure_on" => Date.to_iso8601(Date.add(issued_on, 61))
      })

      submit_one(
        cancel_op(%{
          "group_id" => "old",
          "occurred_on" => Date.to_iso8601(issued_on),
          "refund_method" => "hotel_credit"
        })
      )

      assert get_guest_credit("guest-22")["lots"] == []
      assert get_ledger()["credit_liability_cents"] == 0

      yesterday = Date.to_iso8601(Date.add(today, -1))
      assert get_guest_credit("guest-22", %{"on" => yesterday})["available_cents"] == 1100
    end

    test "rejects an unusable on date", %{conn: conn} do
      for path <- [
            "/api/v1/ledger?on=2027-02-30",
            "/api/v1/ledger?on=soon",
            "/api/v1/ledger?on=",
            "/api/v1/ledger?on[]=2027-01-01",
            "/api/v1/guests/guest-22/credit?on=20270101"
          ] do
        assert json_response(get(conn, path), 400) == %{"error" => %{"code" => "invalid_date"}},
               "expected invalid_date for #{path}"
      end
    end
  end
end
