defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp get_group(group_id) do
    {body, 200} = api_get(build_conn(), "/api/v1/groups/#{group_id}")
    body["data"]
  end

  defp get_ledger(query \\ "") do
    api_get(build_conn(), "/api/v1/ledger#{query}")
  end

  defp get_credit(guest_id, query \\ "") do
    api_get(build_conn(), "/api/v1/guests/#{guest_id}/credit#{query}")
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  # Cancels a cash-funded flexible group with hotel credit, creating a
  # 5,500-cent lot for guest-22 out of 5,000 cents of cash.
  defp issue_credit(opts \\ []) do
    group_id = Keyword.get(opts, :group_id, "group-91")
    open_op_id = Keyword.get(opts, :open_operation_id, "op-9001")
    cancel_op_id = Keyword.get(opts, :cancel_operation_id, "op-9101")
    occurred_on = Keyword.get(opts, :occurred_on, "2026-04-01")
    cash = Keyword.get(opts, :cash_cents, 5_000)

    open =
      open_group_op(%{
        "operation_id" => open_op_id,
        "group_id" => group_id,
        "occurred_on" => "2026-01-05",
        "arrival_on" => "2026-06-01",
        "departure_on" => "2026-06-04",
        "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
      })

    payment =
      cash_payment_op(%{
        "operation_id" => "#{open_op_id}-pay",
        "group_id" => group_id,
        "amount_cents" => cash
      })

    cancellation =
      cancel_op(%{
        "operation_id" => cancel_op_id,
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })

    {body, 200} = post_ops([open, payment, cancellation])
    body
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window" do
      {_, 200} =
        post_ops([
          open_group_op(%{
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-13"
          })
        ])

      group = get_group("group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-24"
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window" do
      {_, 200} =
        post_ops([
          open_group_op(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          })
        ])

      group = get_group("group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-05-11"
    end

    test "advance-purchase groups are non-refundable with no refundable_until" do
      {_, 200} =
        post_ops([
          open_group_op(%{"occurred_on" => "2027-01-02", "rate_plan" => "advance_purchase"})
        ])

      group = get_group("group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling keeps the policy version and recomputes refundable_until" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([
          reschedule_op(%{"occurred_on" => "2026-10-10", "new_arrival_on" => "2027-06-01"})
        ])

      applied = result(body)
      assert applied["policy_version"] == "flex-14"
      assert applied["refundable_until"] == "2027-05-18"

      group = get_group("group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-05-18"
    end

    test "rescheduling an advance-purchase group keeps a nil refundable_until" do
      {_, 200} = post_ops([open_group_op(%{"rate_plan" => "advance_purchase"})])

      {body, 200} =
        post_ops([
          reschedule_op(%{"occurred_on" => "2026-10-10", "new_arrival_on" => "2026-12-20"})
        ])

      applied = result(body)
      assert applied["policy_version"] == "advance-nonrefundable"
      assert applied["refundable_until"] == nil
    end

    test "groups created before the release keep the policy their booking date implies" do
      {:ok, _group} =
        Repo.insert(%Group{
          group_id: "legacy-1",
          guest_id: "guest-1",
          property_id: "p-1",
          booked_on: ~D[2026-06-05],
          arrival_on: ~D[2026-09-01],
          departure_on: ~D[2026-09-03],
          rate_plan: "flexible",
          status: "active",
          revision: 1,
          policy_version: nil,
          lodging_total_cents: 10_000,
          deposit_due_cents: 2_000
        })

      {:ok, _group} =
        Repo.insert(%Group{
          group_id: "legacy-2",
          guest_id: "guest-1",
          property_id: "p-1",
          booked_on: ~D[2027-02-01],
          arrival_on: ~D[2027-06-01],
          departure_on: ~D[2027-06-03],
          rate_plan: "flexible",
          status: "active",
          revision: 1,
          policy_version: nil,
          lodging_total_cents: 10_000,
          deposit_due_cents: 2_000
        })

      {:ok, _group} =
        Repo.insert(%Group{
          group_id: "legacy-3",
          guest_id: "guest-1",
          property_id: "p-1",
          booked_on: ~D[2026-06-05],
          arrival_on: ~D[2026-09-01],
          departure_on: ~D[2026-09-03],
          rate_plan: "advance_purchase",
          status: "active",
          revision: 1,
          policy_version: nil,
          lodging_total_cents: 10_000,
          deposit_due_cents: 10_000
        })

      flex_14 = get_group("legacy-1")
      assert flex_14["policy_version"] == "flex-14"
      assert flex_14["refundable_until"] == "2026-08-18"

      flex_30 = get_group("legacy-2")
      assert flex_30["policy_version"] == "flex-30"
      assert flex_30["refundable_until"] == "2027-05-02"

      advance = get_group("legacy-3")
      assert advance["policy_version"] == "advance-nonrefundable"
      assert advance["refundable_until"] == nil
    end
  end

  describe "cancellation windows" do
    test "flex-30 groups are refundable through refundable_until and retained after" do
      open = fn op_id ->
        open_group_op(%{
          "operation_id" => "open-#{op_id}",
          "group_id" => "group-3#{op_id}",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        })
      end

      pay = fn op_id ->
        cash_payment_op(%{
          "operation_id" => "pay-#{op_id}",
          "group_id" => "group-3#{op_id}",
          "amount_cents" => 5_000
        })
      end

      cancel = fn op_id, occurred_on ->
        cancel_op(%{
          "operation_id" => "cancel-#{op_id}",
          "group_id" => "group-3#{op_id}",
          "occurred_on" => occurred_on
        })
      end

      {_, 200} = post_ops([open.("a"), pay.("a")])
      {_, 200} = post_ops([open.("b"), pay.("b")])

      {body, 200} = post_ops([cancel.("a", "2027-05-11")])
      assert result(body)["refunded_cents"] == 5_000
      assert result(body)["retained_cents"] == 0
      assert result(body)["credit_issued_cents"] == 0

      {body, 200} = post_ops([cancel.("b", "2027-05-12")])
      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 5_000
      assert result(body)["credit_issued_cents"] == 0
    end
  end

  describe "hotel credit on cancellation" do
    test "converts refundable cash into a credit lot worth 110%" do
      {_, 200} = post_ops([open_group_op()])

      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])

      {body, 200} =
        post_ops([
          cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        ])

      assert result(body) == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      assert get_group("group-81")["status"] == "cancelled"

      {credit, 200} = get_credit("guest-22")

      assert credit == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 11_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-4001",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             }

      {ledger, 200} = get_ledger()

      assert ledger["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000,
               "credit_shortfall_cents" => 0
             }
    end

    test "rounds the 10% bonus half-up" do
      {_, 200} =
        post_ops([
          open_group_op(%{"group_id" => "group-81", "operation_id" => "op-1"}),
          cash_payment_op(%{
            "group_id" => "group-81",
            "operation_id" => "op-1p",
            "amount_cents" => 1_506
          })
        ])

      {_, 200} =
        post_ops([
          open_group_op(%{"group_id" => "group-82", "operation_id" => "op-2"}),
          cash_payment_op(%{
            "group_id" => "group-82",
            "operation_id" => "op-2p",
            "amount_cents" => 1_505
          })
        ])

      {_, 200} =
        post_ops([
          open_group_op(%{"group_id" => "group-83", "operation_id" => "op-3"}),
          cash_payment_op(%{
            "group_id" => "group-83",
            "operation_id" => "op-3p",
            "amount_cents" => 1_504
          })
        ])

      {body, 200} =
        post_ops([
          cancel_op(%{
            "group_id" => "group-81",
            "operation_id" => "op-1c",
            "refund_method" => "hotel_credit"
          }),
          cancel_op(%{
            "group_id" => "group-82",
            "operation_id" => "op-2c",
            "refund_method" => "hotel_credit"
          }),
          cancel_op(%{
            "group_id" => "group-83",
            "operation_id" => "op-3c",
            "refund_method" => "hotel_credit"
          })
        ])

      # 150.6 -> 151, 150.5 -> 151 (half-up), 150.4 -> 150
      assert result(body, 0)["credit_issued_cents"] == 1_657
      assert result(body, 1)["credit_issued_cents"] == 1_656
      assert result(body, 2)["credit_issued_cents"] == 1_654
    end

    test "omitting refund_method refunds cash and issues no credit" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])

      {body, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      assert result(body)["refunded_cents"] == 10_000
      assert result(body)["credit_issued_cents"] == 0

      {credit, 200} = get_credit("guest-22")

      assert credit == %{
               "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
             }
    end

    test "hotel credit is unavailable for late flexible cancellations" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} =
        post_ops([
          cancel_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      assert result(body) == %{
               "operation_id" => "op-4001",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = get_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5_000

      {credit, 200} = get_credit("guest-22")
      assert credit["data"]["available_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 5_000
      assert ledger["data"]["cash_converted_to_credit_cents"] == 0
    end

    test "advance-purchase groups may not choose hotel credit" do
      {_, 200} = post_ops([open_group_op(%{"rate_plan" => "advance_purchase"})])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} =
        post_ops([
          cancel_op(%{"occurred_on" => "2026-10-10", "refund_method" => "hotel_credit"})
        ])

      assert result(body)["code"] == "refund_method_not_available"
      assert get_group("group-81")["status"] == "active"
    end

    test "unknown refund methods are rejected" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "coupon"})])

      assert result(body)["code"] == "refund_method_not_available"
      assert get_group("group-81")["status"] == "active"
    end

    test "a rejected refund method leaves the group and ledger untouched" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {_, 200} =
        post_ops([
          cancel_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      {body, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4002",
            "occurred_on" => "2026-11-27",
            "expected_revision" => 2
          })
        ])

      assert result(body)["status"] == "applied"
      assert result(body)["retained_cents"] == 5_000
      assert result(body)["revision"] == 3
    end

    test "revision is checked before refund method availability" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([
          cancel_op(%{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit",
            "expected_revision" => 5
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-4001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }
    end
  end

  describe "applying hotel credit" do
    setup do
      issue_credit()
      :ok
    end

    test "applies credit to the outstanding deposit and reports totals" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_500})
        ])

      assert result(body) == %{
               "operation_id" => "op-5001",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 4_500,
               "outstanding_deposit_cents" => 10_000,
               "revision" => 3
             }

      group = get_group("group-81")
      assert group["cash_paid_cents"] == 5_000
      assert group["credit_paid_cents"] == 4_500
      assert group["deposit_paid_cents"] == 9_500
      assert group["outstanding_deposit_cents"] == 10_000

      {credit, 200} = get_credit("guest-22")
      assert credit["data"]["available_cents"] == 1_000
    end

    test "consumes lots by earliest expiry and then source operation id" do
      {_, 200} = post_ops([open_group_op()])

      issue_credit(
        cancel_operation_id: "op-b",
        group_id: "group-92",
        open_operation_id: "op-9201",
        occurred_on: "2026-04-05"
      )

      # Lots: op-9101 expires 2027-04-01, op-b expires 2027-04-05.
      {body, 200} = post_ops([apply_hotel_credit_op(%{"amount_cents" => 3_000})])

      assert result(body)["status"] == "applied"

      {credit, 200} = get_credit("guest-22")
      assert credit["data"]["available_cents"] == 8_000

      assert Enum.map(credit["data"]["lots"], & &1["source_operation_id"]) == ["op-9101", "op-b"]
      assert Enum.map(credit["data"]["lots"], & &1["remaining_cents"]) == [2_500, 5_500]

      {_, 200} =
        post_ops([apply_hotel_credit_op(%{"operation_id" => "op-5002", "amount_cents" => 4_000})])

      {credit, 200} = get_credit("guest-22")
      assert Enum.map(credit["data"]["lots"], & &1["source_operation_id"]) == ["op-b"]
      assert Enum.map(credit["data"]["lots"], & &1["remaining_cents"]) == [4_000]
    end

    test "breaks equal-expiry ties by source operation id" do
      {_, 200} = post_ops([open_group_op()])

      issue_credit(
        cancel_operation_id: "op-9100",
        group_id: "group-92",
        open_operation_id: "op-9201",
        occurred_on: "2026-04-01"
      )

      # Both lots expire 2027-04-01; op-9100 sorts before op-9101.
      {_, 200} = post_ops([apply_hotel_credit_op(%{"amount_cents" => 5_500})])

      {credit, 200} = get_credit("guest-22")

      assert Enum.map(credit["data"]["lots"], & &1["source_operation_id"]) == ["op-9101"]
      assert Enum.map(credit["data"]["lots"], & &1["remaining_cents"]) == [5_500]
    end

    test "rejects with insufficient_credit without advancing a revision" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 19_500})
        ])

      assert result(body) == %{
               "operation_id" => "op-5001",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      assert get_group("group-81")["revision"] == 1

      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{
            "operation_id" => "op-5002",
            "expected_revision" => 1,
            "amount_cents" => 1_000
          })
        ])

      assert result(body)["status"] == "applied"
      assert result(body)["revision"] == 2
    end

    test "rejects amounts above the outstanding deposit" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 19_501})
        ])

      assert result(body)["code"] == "payment_exceeds_outstanding"
    end

    test "rejects unusable amounts before considering credit" do
      {_, 200} = post_ops([open_group_op()])

      for {amount, index} <- Enum.with_index([0, -1, 1.5]) do
        {body, 200} =
          post_ops([
            apply_hotel_credit_op(%{
              "operation_id" => "op-590#{index}",
              "occurred_on" => "2026-10-20",
              "amount_cents" => amount
            })
          ])

        assert result(body)["code"] == "invalid_amount",
               "expected invalid_amount for #{inspect(amount)}"
      end
    end

    test "evaluates expiry using the operation's occurred_on date" do
      {_, 200} = post_ops([open_group_op()])

      # Lot expires 2027-04-01: usable on that date, expired the next day.
      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2027-04-01", "amount_cents" => 1_000})
        ])

      assert result(body)["status"] == "applied"

      {_, 200} =
        post_ops([
          open_group_op(%{"group_id" => "group-82", "operation_id" => "op-1002"})
        ])

      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{
            "group_id" => "group-82",
            "operation_id" => "op-5002",
            "occurred_on" => "2027-04-02",
            "amount_cents" => 1_000
          })
        ])

      assert result(body)["code"] == "insufficient_credit"
    end

    test "rejects when the group is inactive" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      {body, 200} = post_ops([apply_hotel_credit_op(%{"amount_cents" => 1_000})])
      assert result(body)["code"] == "group_not_active"
    end

    test "rejects against missing groups" do
      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{"group_id" => "group-missing", "amount_cents" => 1_000})
        ])

      assert result(body)["code"] == "group_not_found"
    end

    test "revision is checked before domain rules" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([
          apply_hotel_credit_op(%{"expected_revision" => 9, "amount_cents" => 999_999})
        ])

      assert result(body) == %{
               "operation_id" => "op-5001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
    end
  end

  describe "settling a group funded by credit" do
    setup do
      issue_credit()
      :ok
    end

    test "refundable cash cancellation restores applied credit to its original lot" do
      {_, 200} = post_ops([open_group_op()])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 3_000})
        ])

      {body, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 0
      assert result(body)["credit_issued_cents"] == 0

      {credit, 200} = get_credit("guest-22")

      assert credit["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-9101",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-04-01"
                 }
               ]
             }
    end

    test "refundable hotel-credit cancellation converts cash while restoring applied credit" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 3_000})
        ])

      {body, 200} =
        post_ops([
          cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        ])

      applied = result(body)
      assert applied["refunded_cents"] == 0
      assert applied["retained_cents"] == 0
      assert applied["credit_issued_cents"] == 5_500

      {credit, 200} = get_credit("guest-22")

      assert credit["data"]["available_cents"] == 11_000

      assert Enum.map(credit["data"]["lots"], & &1["source_operation_id"]) == [
               "op-9101",
               "op-4001"
             ]

      assert Enum.map(credit["data"]["lots"], & &1["remaining_cents"]) == [5_500, 5_500]

      {ledger, 200} = get_ledger()

      assert ledger["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000,
               "credit_shortfall_cents" => 0
             }
    end

    test "restored credit whose expiry passed on the cancellation date expires immediately" do
      open =
        open_group_op(%{
          "occurred_on" => "2026-01-02",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-04",
          "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
        })

      {_, 200} = post_ops([open])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-04-02", "amount_cents" => 3_000})
        ])

      # Refundable: cancellation is 14+ days before 2028-06-01, but the lot
      # expired on 2027-04-01, before the cancellation date.
      {body, 200} = post_ops([cancel_op(%{"occurred_on" => "2027-05-01"})])

      assert result(body)["status"] == "applied"

      {credit, 200} = get_credit("guest-22", "?on=2027-05-01")
      assert credit["data"]["available_cents"] == 0
      assert credit["data"]["lots"] == []

      # Before the expiry the unapplied remainder was still available.
      {credit, 200} = get_credit("guest-22", "?on=2026-10-01")
      assert credit["data"]["available_cents"] == 2_500

      {ledger, 200} = get_ledger("?on=2027-05-01")
      assert ledger["data"]["credit_liability_cents"] == 0
    end

    test "non-refundable cancellation consumes applied credit" do
      {_, 200} = post_ops([open_group_op()])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 3_000})
        ])

      {body, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-27"})])

      applied = result(body)
      assert applied["refunded_cents"] == 0
      assert applied["retained_cents"] == 0
      assert applied["credit_issued_cents"] == 0

      {credit, 200} = get_credit("guest-22")

      assert credit["data"]["available_cents"] == 2_500

      assert [
               %{
                 "source_operation_id" => "op-9101",
                 "remaining_cents" => 2_500,
                 "expires_on" => "2027-04-01"
               }
             ] =
               credit["data"]["lots"]

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 2_500
    end
  end
end
