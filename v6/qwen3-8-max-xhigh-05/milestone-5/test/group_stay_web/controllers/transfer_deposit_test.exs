defmodule GroupStayWeb.TransferDepositTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-10",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 3000
      },
      overrides
    )
  end

  defp transfer(conn, overrides \\ %{}) do
    %{"results" => [result]} = submit_batch(conn, [transfer_op(overrides)])
    result
  end

  defp open_second_group(conn, overrides \\ %{}) do
    open_group_fixture(
      conn,
      Map.merge(
        %{
          "operation_id" => "op-open-82",
          "group_id" => "group-82",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23"
        },
        overrides
      )
    )
  end

  defp pay(conn, amount_cents, overrides \\ %{}) do
    pay_group(
      conn,
      "group-81",
      amount_cents,
      Map.merge(%{"operation_id" => "op-pay"}, overrides)
    )
  end

  defp issue_credit(conn) do
    open_group_fixture(conn, %{
      "operation_id" => "op-open-83",
      "group_id" => "group-83",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-23"
    })

    pay_group(conn, "group-83", 5000, %{"operation_id" => "op-pay-83"})
    cancel_group(conn, "group-83", "2026-11-26", %{"refund_method" => "hotel_credit"})
  end

  defp apply_credit(conn, group_id, amount_cents, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  defp reduce(conn, payment_operation_id, amount_cents, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-11",
          "payment_operation_id" => payment_operation_id,
          "amount_cents" => amount_cents
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  defp charge_back(conn, payment_operation_id, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-charge-back",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-12",
          "payment_operation_id" => payment_operation_id
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  defp payment_data(conn, payment_operation_id) do
    conn
    |> Phoenix.ConnTest.dispatch(
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/payments/#{payment_operation_id}"
    )
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end

  defp room_by_id(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  describe "applying" do
    test "moves cash between two active groups of the same guest", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      result = transfer(conn)

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-82",
               "amount_cents" => 3000,
               "source_outstanding_deposit_cents" => 17500,
               "destination_outstanding_deposit_cents" => 16500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = group_data(conn, "group-81")
      assert source["deposit_paid_cents"] == 2000
      assert source["cash_paid_cents"] == 2000
      assert source["outstanding_deposit_cents"] == 17500
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 2000
      assert room_by_id(source, "room-b")["cash_paid_cents"] == 0

      destination = group_data(conn, "group-82")
      assert destination["deposit_paid_cents"] == 3000
      assert destination["cash_paid_cents"] == 3000
      assert destination["outstanding_deposit_cents"] == 16500
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 3000
      assert room_by_id(destination, "room-b")["cash_paid_cents"] == 0

      # A transfer changes no ledger total.
      assert ledger_data(conn) == %{
               "cash_held_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "takes from the source in reverse allocation order regardless of funding kind", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 5000)
      issue_credit(conn)
      assert apply_credit(conn, "group-81", 2000)["status"] == "applied"

      result = transfer(conn, %{"amount_cents" => 2500})

      assert result["status"] == "applied"

      # The most recently created allocation (the credit) is taken first.
      source = group_data(conn, "group-81")
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 4500
      assert room_by_id(source, "room-a")["credit_paid_cents"] == 0
      assert source["deposit_paid_cents"] == 4500

      destination = group_data(conn, "group-82")
      assert room_by_id(destination, "room-a")["credit_paid_cents"] == 2000
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 500
      assert destination["deposit_paid_cents"] == 2500
      assert destination["outstanding_deposit_cents"] == 17000

      assert ledger_data(conn)["cash_held_cents"] == 5000
      assert ledger_data(conn)["credit_liability_cents"] == 5500
    end

    test "fills the destination's rooms in their original order", %{conn: conn} do
      open_second_group(conn, %{
        "rooms" => [
          %{"room_id" => "room-x", "nightly_rate_cents" => 1000},
          %{"room_id" => "room-y", "nightly_rate_cents" => 15000}
        ]
      })

      pay(conn, 9000)
      pay(conn, 1000, %{"operation_id" => "op-pay-2"})

      result = transfer(conn, %{"amount_cents" => 1500})

      assert result["status"] == "applied"

      # room-x's 600 deposit fills before room-y receives anything.
      destination = group_data(conn, "group-82")
      assert room_by_id(destination, "room-x")["cash_paid_cents"] == 600
      assert room_by_id(destination, "room-y")["cash_paid_cents"] == 900

      source = group_data(conn, "group-81")
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 8500
      assert room_by_id(source, "room-b")["cash_paid_cents"] == 0
    end

    test "each moved allocation keeps its provenance", %{conn: conn} do
      open_second_group(conn, %{
        "rooms" => [
          %{"room_id" => "room-x", "nightly_rate_cents" => 1000},
          %{"room_id" => "room-y", "nightly_rate_cents" => 15000}
        ]
      })

      pay(conn, 9000)
      pay(conn, 1000, %{"operation_id" => "op-pay-2"})
      transfer(conn, %{"amount_cents" => 1500})

      # Reducing op-pay-2 removes exactly its moved cash, newest portion
      # first, leaving op-pay's moved portion in place.
      assert reduce(conn, "op-pay-2", 1000)["status"] == "applied"

      destination = group_data(conn, "group-82")
      assert room_by_id(destination, "room-x")["cash_paid_cents"] == 0
      assert room_by_id(destination, "room-y")["cash_paid_cents"] == 500

      assert payment_data(conn, "op-pay-2")["held_cents"] == 0
      assert payment_data(conn, "op-pay")["held_cents"] == 9000

      assert payment_data(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8500},
               %{"group_id" => "group-82", "amount_cents" => 500}
             ]
    end

    test "a complete transfer of all held funding is valid", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)
      issue_credit(conn)
      assert apply_credit(conn, "group-81", 2000)["status"] == "applied"

      result = transfer(conn, %{"amount_cents" => 7000})

      assert result["status"] == "applied"
      assert result["source_outstanding_deposit_cents"] == 19500
      assert result["destination_outstanding_deposit_cents"] == 12500

      source = group_data(conn, "group-81")
      assert source["deposit_paid_cents"] == 0
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 0
      assert room_by_id(source, "room-a")["credit_paid_cents"] == 0

      destination = group_data(conn, "group-82")
      assert destination["deposit_paid_cents"] == 7000
      assert destination["cash_paid_cents"] == 5000
      assert destination["credit_paid_cents"] == 2000
    end

    test "transferred credit keeps its lot with expiry still paused", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn)
      assert apply_credit(conn, "group-81", 3000)["status"] == "applied"
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 2500

      result = transfer(conn, %{"amount_cents" => 3000})

      assert result["status"] == "applied"

      # No bonus is computed and the credit remains applied, not available.
      credit = guest_credit_data(conn, "guest-22")
      assert credit["available_cents"] == 2500

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-group-83",
                 "remaining_cents" => 2500,
                 "expires_on" => "2027-11-26"
               }
             ]

      assert ledger_data(conn)["credit_liability_cents"] == 5500
      assert group_data(conn, "group-82")["credit_paid_cents"] == 3000
    end
  end

  describe "later settlement" do
    test "transferred cash settles under the destination's cancellation policy", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)
      transfer(conn)

      cancellation = cancel_group(conn, "group-82", "2026-11-26")

      assert cancellation["status"] == "applied"
      assert cancellation["refunded_cents"] == 3000
      assert cancellation["retained_cents"] == 0

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 2000
      assert ledger["cash_refunded_cents"] == 3000

      # The source group's remaining cash is untouched.
      assert group_data(conn, "group-81")["cash_paid_cents"] == 2000
    end

    test "transferred cash is retained under a non-refundable destination cancellation", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 5000)
      transfer(conn)

      # Inside group-82's cancellation window the settlement is non-refundable.
      cancellation = cancel_group(conn, "group-82", "2026-12-09")

      assert cancellation["refunded_cents"] == 0
      assert cancellation["retained_cents"] == 3000

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 2000
      assert ledger["cash_retained_cents"] == 3000
    end

    test "transferred cash converted at the destination receives the bonus there", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 5000)
      transfer(conn)

      cancellation =
        cancel_group(conn, "group-82", "2026-11-26", %{"refund_method" => "hotel_credit"})

      assert cancellation["credit_issued_cents"] == 3300

      ledger = ledger_data(conn)
      assert ledger["cash_converted_to_credit_cents"] == 3000
      assert ledger["cash_held_cents"] == 2000
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 3300
    end

    test "transferred credit restores to its original lot without another bonus", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn)
      assert apply_credit(conn, "group-81", 3000)["status"] == "applied"
      transfer(conn, %{"amount_cents" => 3000})

      cancellation = cancel_group(conn, "group-82", "2026-11-26")

      assert cancellation["refunded_cents"] == 0
      assert cancellation["retained_cents"] == 0
      assert cancellation["credit_issued_cents"] == 0

      # The amount returns to its original lot with its original expiry.
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500

      assert guest_credit_data(conn, "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-group-83",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-11-26"
               }
             ]

      assert ledger_data(conn)["credit_liability_cents"] == 5500
    end

    test "restored transferred credit follows the existing expiry rules", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-old",
        "group_id" => "group-old",
        "occurred_on" => "2024-12-01",
        "arrival_on" => "2025-02-10",
        "departure_on" => "2025-02-13"
      })

      pay_group(conn, "group-old", 5000, %{"operation_id" => "op-pay-old"})
      cancel_group(conn, "group-old", "2025-01-01", %{"refund_method" => "hotel_credit"})

      open_second_group(conn)

      assert apply_credit(conn, "group-81", 5500, %{"occurred_on" => "2025-12-15"})[
               "status"
             ] == "applied"

      transfer(conn, %{"amount_cents" => 5500})

      # The lot expired on 2026-01-01; restoring it on 2026-02-01 expires the
      # amount instead of making it available.
      cancellation = cancel_group(conn, "group-82", "2026-02-01")

      assert cancellation["credit_issued_cents"] == 0
      assert ledger_data(conn)["credit_liability_cents"] == 0
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 0
    end

    test "non-refundable settlement consumes transferred credit normally", %{conn: conn} do
      open_second_group(conn)
      issue_credit(conn)
      assert apply_credit(conn, "group-81", 3000)["status"] == "applied"
      transfer(conn, %{"amount_cents" => 3000})

      # Inside group-82's cancellation window the settlement is non-refundable.
      cancellation = cancel_group(conn, "group-82", "2026-12-09")

      assert cancellation["retained_cents"] == 0
      assert cancellation["credit_issued_cents"] == 0

      assert ledger_data(conn)["credit_liability_cents"] == 2500
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 2500
    end

    test "restored transferred credit extinguishes unrecovered clawback first", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
      open_second_group(conn)

      open_group_fixture(conn, %{
        "operation_id" => "op-open-83",
        "group_id" => "group-83",
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      })

      assert apply_credit(conn, "group-82", 5500)["status"] == "applied"
      assert charge_back(conn, "op-pay")["status"] == "applied"
      assert ledger_data(conn)["credit_shortfall_cents"] == 500

      # The applied credit moves to group-83 and returns from there.
      assert transfer(conn, %{
               "source_group_id" => "group-82",
               "destination_group_id" => "group-83",
               "amount_cents" => 5500
             })["status"] == "applied"

      cancellation = cancel_group(conn, "group-83", "2026-11-30")

      assert cancellation["credit_issued_cents"] == 0

      ledger = ledger_data(conn)
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 5000
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5000
    end
  end

  describe "reductions and chargebacks across groups" do
    test "a reduction follows the payment's allocations across groups", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 10000)
      transfer(conn, %{"amount_cents" => 4000})

      # The revision guard applies only to the addressed payment group.
      result = reduce(conn, "op-pay", 2000, %{"expected_revision" => 3})

      # The most recently created allocation is the transferred portion in
      # group-82, so the reduction removes it there.
      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 2000,
               "outstanding_deposit_cents" => 13500,
               "revision" => 4
             }

      destination = group_data(conn, "group-82")
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 2000
      assert destination["deposit_paid_cents"] == 2000
      assert destination["outstanding_deposit_cents"] == 17500
      # Every group whose funding changed increments its revision.
      assert destination["revision"] == 3

      # The addressed group's revision increments even though no funding was
      # removed from its rooms.
      source = group_data(conn, "group-81")
      assert source["cash_paid_cents"] == 6000
      assert source["revision"] == 4

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 8000
      assert ledger["cash_reduced_cents"] == 2000
    end

    test "a chargeback removes held cash across all groups holding it", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 10000)
      transfer(conn, %{"amount_cents" => 4000})

      result = charge_back(conn, "op-pay")

      assert result == %{
               "operation_id" => "op-charge-back",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 4
             }

      assert group_data(conn, "group-81")["cash_paid_cents"] == 0
      assert group_data(conn, "group-82")["cash_paid_cents"] == 0
      assert group_data(conn, "group-82")["outstanding_deposit_cents"] == 19500
      assert group_data(conn, "group-82")["revision"] == 3

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10000

      # The payment participated in a transfer, so its held-by-group list is
      # returned, empty once nothing remains.
      assert payment_data(conn, "op-pay")["held_by_group"] == []
    end

    test "a chargeback still addresses the original payment group when all held cash moved", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 5000)
      transfer(conn, %{"amount_cents" => 5000})

      result = charge_back(conn, "op-pay")

      assert result["status"] == "applied"
      assert result["group_id"] == "group-81"
      assert result["charged_back_cents"] == 5000
      assert result["outstanding_deposit_cents"] == 19500
      assert result["revision"] == 4

      source = group_data(conn, "group-81")
      assert source["deposit_paid_cents"] == 0
      assert source["revision"] == 4

      assert group_data(conn, "group-82")["revision"] == 3
      assert group_data(conn, "group-82")["outstanding_deposit_cents"] == 19500
    end
  end

  describe "payment statement evolution" do
    test "adds held_by_group once the payment's cash has participated in a transfer", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 10000)
      transfer(conn)

      statement = payment_data(conn, "op-pay")

      assert statement["held_cents"] == 10000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7000},
               %{"group_id" => "group-82", "amount_cents" => 3000}
             ]

      held_by_group_total =
        statement["held_by_group"]
        |> Enum.map(& &1["amount_cents"])
        |> Enum.sum()

      assert held_by_group_total == statement["held_cents"]
    end

    test "orders held_by_group by group_id", %{conn: conn} do
      open_second_group(conn, %{"operation_id" => "op-open-70", "group_id" => "group-70"})
      pay(conn, 5000)

      transfer(conn, %{"destination_group_id" => "group-70", "amount_cents" => 2000})

      assert payment_data(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-70", "amount_cents" => 2000},
               %{"group_id" => "group-81", "amount_cents" => 3000}
             ]
    end

    test "omits groups with no held cash and returns an empty list once none remains", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 5000)
      transfer(conn, %{"amount_cents" => 2000})

      # The transferred portion is removed first, leaving group-82 with no
      # held cash from the payment.
      assert reduce(conn, "op-pay", 2000)["status"] == "applied"

      assert payment_data(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3000}
             ]

      cancel_group(conn, "group-81", "2026-11-26")
      assert payment_data(conn, "op-pay")["held_by_group"] == []
    end

    test "transferred funding can itself be transferred again", %{conn: conn} do
      open_second_group(conn)

      open_group_fixture(conn, %{
        "operation_id" => "op-open-83",
        "group_id" => "group-83",
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      })

      pay(conn, 5000)
      transfer(conn, %{"amount_cents" => 2000})

      result =
        transfer(conn, %{
          "operation_id" => "op-transfer-2",
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 1500
        })

      assert result["status"] == "applied"
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2

      assert group_data(conn, "group-81")["cash_paid_cents"] == 3000
      assert group_data(conn, "group-82")["cash_paid_cents"] == 500
      assert group_data(conn, "group-83")["cash_paid_cents"] == 1500

      assert payment_data(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3000},
               %{"group_id" => "group-82", "amount_cents" => 500},
               %{"group_id" => "group-83", "amount_cents" => 1500}
             ]
    end

    test "payments that never participated in a transfer keep the earlier shape", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)
      pay(conn, 5000, %{"operation_id" => "op-pay-2"})

      # The transfer draws op-pay-2's cash first.
      transfer(conn, %{"amount_cents" => 2000})

      untouched = payment_data(conn, "op-pay")
      refute Map.has_key?(untouched, "held_by_group")

      assert untouched == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 5000,
               "held_cents" => 5000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert Map.has_key?(payment_data(conn, "op-pay-2"), "held_by_group")
    end
  end

  describe "rejections" do
    test "rejects group_not_found for a missing source group", %{conn: conn} do
      open_second_group(conn)

      result = transfer(conn, %{"source_group_id" => "group-missing"})

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-missing"
      assert group_data(conn, "group-82")["revision"] == 1
    end

    test "rejects group_not_found for a missing destination group", %{conn: conn} do
      result = transfer(conn, %{"destination_group_id" => "group-missing"})

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-missing"
      assert group_data(conn, "group-81")["revision"] == 1
    end

    test "resolves source existence before destination existence", %{conn: conn} do
      result =
        transfer(conn, %{
          "source_group_id" => "group-missing-a",
          "destination_group_id" => "group-missing-b"
        })

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-missing-a"
    end

    test "rejects a stale source revision before the transfer rules", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      # An invalid amount would also fail, but the revision guard comes first.
      result = transfer(conn, %{"expected_revision" => 9, "amount_cents" => 0})

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["expected_revision"] == 9
      assert result["actual_revision"] == 2
    end

    test "rejects a stale destination revision with the destination's details", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      result =
        transfer(conn, %{"expected_revision" => 2, "destination_expected_revision" => 9})

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-82"
      assert result["expected_revision"] == 9
      assert result["actual_revision"] == 1
    end

    test "checks the source revision before the destination revision", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      result =
        transfer(conn, %{"expected_revision" => 8, "destination_expected_revision" => 9})

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["expected_revision"] == 8
    end

    test "resolves existence before comparing revisions", %{conn: conn} do
      result =
        transfer(conn, %{
          "expected_revision" => 9,
          "destination_group_id" => "group-missing"
        })

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-missing"
    end

    test "rejects invalid_transfer when the groups are the same", %{conn: conn} do
      result = transfer(conn, %{"destination_group_id" => "group-81"})

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_transfer"
      assert group_data(conn, "group-81")["revision"] == 1
    end

    test "rejects invalid_transfer when the groups have different guests", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-99",
        "group_id" => "group-99",
        "guest_id" => "guest-99"
      })

      result = transfer(conn, %{"destination_group_id" => "group-99"})

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_transfer"
    end

    test "rejects invalid_transfer before group_not_active", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-99",
        "group_id" => "group-99",
        "guest_id" => "guest-99"
      })

      cancel_group(conn, "group-99", "2026-11-26")

      result = transfer(conn, %{"destination_group_id" => "group-99"})

      assert result["code"] == "invalid_transfer"
    end

    test "rejects group_not_active for an inactive source with its group_id", %{conn: conn} do
      open_second_group(conn)
      cancel_group(conn, "group-81", "2026-11-26")

      result = transfer(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-81"
    end

    test "rejects group_not_active for an inactive destination with its group_id", %{conn: conn} do
      open_second_group(conn)
      cancel_group(conn, "group-82", "2026-11-26")

      result = transfer(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-82"
    end

    test "rejects invalid_amount for non-positive amounts", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      ops =
        for {amount, index} <- Enum.with_index([0, -100, "1000", 10.5, true]) do
          transfer_op(%{"operation_id" => "op-transfer-#{index}", "amount_cents" => amount})
        end

      %{"results" => results} = submit_batch(conn, ops)

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_amount"))

      assert group_data(conn, "group-81")["revision"] == 2
      assert group_data(conn, "group-82")["revision"] == 1
    end

    test "rejects transfer_exceeds_held_funding when the source holds less than requested", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 1000)

      result = transfer(conn, %{"amount_cents" => 1001})

      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_held_funding"

      assert group_data(conn, "group-81")["revision"] == 2
      assert group_data(conn, "group-82")["revision"] == 1
      assert group_data(conn, "group-81")["cash_paid_cents"] == 1000
      assert group_data(conn, "group-82")["cash_paid_cents"] == 0
    end

    test "rejects transfer_exceeds_outstanding when the destination deposit cannot take it", %{
      conn: conn
    } do
      open_second_group(conn)
      pay_group(conn, "group-82", 18000, %{"operation_id" => "op-pay-82"})
      pay(conn, 5000)

      result = transfer(conn, %{"amount_cents" => 2000})

      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_outstanding"

      assert group_data(conn, "group-81")["revision"] == 2
      assert group_data(conn, "group-82")["revision"] == 2
      assert group_data(conn, "group-81")["cash_paid_cents"] == 5000
      assert group_data(conn, "group-82")["cash_paid_cents"] == 18000
    end

    test "checks held funding before the destination's outstanding deposit", %{conn: conn} do
      open_second_group(conn)

      result = transfer(conn, %{"amount_cents" => 500})

      assert result["code"] == "transfer_exceeds_held_funding"
    end

    test "checks the amount before the held funding", %{conn: conn} do
      open_second_group(conn)

      result = transfer(conn, %{"amount_cents" => 0})

      assert result["code"] == "invalid_amount"
    end

    test "rejects invalid_operation when identifying data is missing", %{conn: conn} do
      open_second_group(conn)

      ops = [
        transfer_op(%{"operation_id" => "op-transfer-1"}) |> Map.delete("source_group_id"),
        transfer_op(%{"operation_id" => "op-transfer-2"})
        |> Map.delete("destination_group_id"),
        transfer_op(%{"operation_id" => "op-transfer-3"}) |> Map.delete("amount_cents"),
        transfer_op(%{"operation_id" => "op-transfer-4", "source_group_id" => 123})
      ]

      %{"results" => results} = submit_batch(conn, ops)

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_operation"))

      assert group_data(conn, "group-81")["revision"] == 1
      assert group_data(conn, "group-82")["revision"] == 1
    end
  end

  describe "durability" do
    test "a retry returns the exact stored result without moving funding again", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      %{"results" => [first]} = submit_batch(conn, [transfer_op()])
      %{"results" => [retry]} = submit_batch(conn, [transfer_op()])

      assert retry == first

      assert group_data(conn, "group-81")["cash_paid_cents"] == 2000
      assert group_data(conn, "group-81")["revision"] == 3
      assert group_data(conn, "group-82")["cash_paid_cents"] == 3000
      assert group_data(conn, "group-82")["revision"] == 2
      assert ledger_data(conn)["cash_held_cents"] == 5000
    end

    test "reusing the identifier with a different payload is a conflict", %{conn: conn} do
      open_second_group(conn)
      pay(conn, 5000)

      assert transfer(conn)["status"] == "applied"

      result = transfer(conn, %{"amount_cents" => 1000})

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      assert group_data(conn, "group-81")["cash_paid_cents"] == 2000
      assert group_data(conn, "group-82")["cash_paid_cents"] == 3000
    end

    test "a stored rejection is replayed even after later operations make it valid", %{
      conn: conn
    } do
      open_second_group(conn)
      pay(conn, 1000)

      %{"results" => [rejected]} = submit_batch(conn, [transfer_op(%{"amount_cents" => 5000})])
      assert rejected["code"] == "transfer_exceeds_held_funding"

      pay(conn, 5000, %{"operation_id" => "op-pay-2"})

      %{"results" => [retry]} = submit_batch(conn, [transfer_op(%{"amount_cents" => 5000})])

      assert retry == rejected
      assert group_data(conn, "group-81")["cash_paid_cents"] == 6000
      assert group_data(conn, "group-82")["cash_paid_cents"] == 0
    end

    test "operations in the same batch see each other's changes", %{conn: conn} do
      %{"results" => results} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-open-82",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-82",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-23",
            "rate_plan" => "flexible",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
            ]
          },
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 5000,
            "expected_revision" => 1
          },
          transfer_op(%{"expected_revision" => 2, "destination_expected_revision" => 1}),
          %{
            "operation_id" => "op-cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-82"
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]

      transfer_result = Enum.at(results, 2)
      assert transfer_result["source_revision"] == 3
      assert transfer_result["destination_revision"] == 2

      cancellation = Enum.at(results, 3)
      assert cancellation["refunded_cents"] == 3000

      assert ledger_data(conn)["cash_refunded_cents"] == 3000
      assert ledger_data(conn)["cash_held_cents"] == 2000
    end
  end
end
