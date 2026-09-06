defmodule GroupStayWeb.PaymentReductionsTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  # Flexible group, 3 nights: room-a lodging 45000 (due 9000), room-b
  # lodging 52500 (due 10500); the deposit due is 19500.
  defp open_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp open_group!(conn, overrides \\ %{}) do
    result = submit_one(conn, open_operation(overrides))
    assert result["status"] == "applied"
    result
  end

  defp pay!(conn, operation_id, group_id, amount_cents) do
    result =
      submit_one(conn, %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    result
  end

  defp cancel_group!(conn, operation_id, group_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    operation =
      if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation

    result = submit_one(conn, operation)
    assert result["status"] == "applied"
    result
  end

  # Issues a credit lot for guest-22 worth 110% of the cash.
  defp issue_credit!(conn, group_id, cash_cents) do
    open_group!(conn, %{"operation_id" => "op-open-#{group_id}", "group_id" => group_id})
    pay!(conn, "op-pay-#{group_id}", group_id, cash_cents)
    cancel_group!(conn, "op-cancel-#{group_id}", group_id, "2026-11-26", "hotel_credit")
  end

  defp reduce_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 4000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp get_group(conn, group_id) do
    conn |> get(~p"/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp room(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn, on \\ "2027-01-01") do
    conn
    |> get(~p"/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id, on \\ "2027-01-01") do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_payment(conn, payment_operation_id) do
    get(conn, ~p"/api/v1/payments/#{payment_operation_id}")
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the outstanding deposit", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      assert submit_one(conn, reduce_operation()) == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 4000,
               "outstanding_deposit_cents" => 13500,
               "revision" => 3
             }

      # the payment filled room-a 9000 then room-b 1000; the reduction
      # removes room-b's 1000 first, then 3000 from room-a
      data = get_group(conn, "group-81")
      assert room(data, "room-a")["cash_paid_cents"] == 6000
      assert room(data, "room-b")["cash_paid_cents"] == 0
      assert data["cash_paid_cents"] == 6000

      assert ledger(conn)["cash_reduced_cents"] == 4000
      assert ledger(conn)["cash_held_cents"] == 6000

      assert conn |> get_payment("op-pay") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 6000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 4000,
                 "charged_back_cents" => 0
               }
             }
    end

    test "only the target payment's allocations are removed, in reverse fill order", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, "op-pay-1", "group-81", 9500)
      pay!(conn, "op-pay-2", "group-81", 3000)

      # op-pay-1 filled room-a 9000 and room-b 500; op-pay-2 filled room-b
      # 3000. Reducing op-pay-1 by 4000 removes room-b's 500 first, then
      # 3500 from room-a; op-pay-2's allocations are untouched.
      result =
        submit_one(
          conn,
          reduce_operation(%{"payment_operation_id" => "op-pay-1", "amount_cents" => 4000})
        )

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 11000

      data = get_group(conn, "group-81")
      assert room(data, "room-a")["cash_paid_cents"] == 5500
      assert room(data, "room-b")["cash_paid_cents"] == 3000

      %{"data" => statement} = get_payment(conn, "op-pay-1") |> json_response(200)
      assert statement["held_cents"] == 5500
      assert statement["reduced_cents"] == 4000

      %{"data" => statement} = get_payment(conn, "op-pay-2") |> json_response(200)
      assert statement["held_cents"] == 3000
      assert statement["reduced_cents"] == 0
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      submit_one(conn, reduce_operation())

      # the complete remaining held portion is valid
      result =
        submit_one(
          conn,
          reduce_operation(%{"operation_id" => "op-reduce-2", "amount_cents" => 6000})
        )

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 19500

      # nothing held anymore: the payment can never accept another reduction
      result =
        submit_one(
          conn,
          reduce_operation(%{"operation_id" => "op-reduce-3", "amount_cents" => 1})
        )

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"
    end

    test "a reduction beyond the held cash is rejected but a smaller one could succeed", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)
      submit_one(conn, reduce_operation())

      result =
        submit_one(
          conn,
          reduce_operation(%{"operation_id" => "op-reduce-2", "amount_cents" => 6001})
        )

      assert result["status"] == "rejected"
      assert result["code"] == "reduction_exceeds_held_cash"
      assert result["group_id"] == "group-81"

      # nothing changed
      assert get_group(conn, "group-81")["cash_paid_cents"] == 6000
      assert ledger(conn)["cash_reduced_cents"] == 4000
    end

    test "only cash still held can be reduced; settled cash is history", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      # refundable cancellation of room-b: the payment's 1000 there is refunded
      submit_one(conn, %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-b"]
      })

      # the remaining held cash is 9000, all on room-a
      result =
        submit_one(
          conn,
          reduce_operation(%{"amount_cents" => 9001})
        )

      assert result["code"] == "reduction_exceeds_held_cash"

      result =
        submit_one(
          conn,
          reduce_operation(%{"operation_id" => "op-reduce-2", "amount_cents" => 9000})
        )

      assert result["status"] == "applied"

      assert conn |> get_payment("op-pay") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 0,
                 "refunded_cents" => 1000,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 9000,
                 "charged_back_cents" => 0
               }
             }
    end

    test "rejects unusable reduction amounts", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      for {amount, n} <- Enum.with_index([0, -500, nil, "4000", 100.5]) do
        result =
          submit_one(
            conn,
            reduce_operation(%{"operation_id" => "op-reduce-#{n}", "amount_cents" => amount})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end
    end

    test "rejects unknown, non-payment, and rejected payment targets", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      # no durable record exists for the identifier
      result = submit_one(conn, reduce_operation(%{"payment_operation_id" => "op-unknown"}))
      assert result["code"] == "operation_not_found"

      # legacy funding has no durable operation identity and cannot be
      # targeted: payments without an operation_id land in the senior block
      result =
        submit_one(
          conn,
          reduce_operation(%{"operation_id" => "op-reduce-nil", "payment_operation_id" => nil})
        )

      assert result["code"] == "invalid_operation"

      # the open_group record is not a payment
      result =
        submit_one(
          conn,
          reduce_operation(%{
            "operation_id" => "op-reduce-open",
            "payment_operation_id" => "op-open"
          })
        )

      assert result["code"] == "payment_not_reducible"

      # a rejected payment can never accept a reduction
      submit_one(conn, %{
        "operation_id" => "op-pay-rejected",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 99_999_999
      })

      result =
        submit_one(
          conn,
          reduce_operation(%{
            "operation_id" => "op-reduce-rejected",
            "payment_operation_id" => "op-pay-rejected"
          })
        )

      assert result["code"] == "payment_not_reducible"

      assert get_group(conn, "group-81")["revision"] == 2
    end

    test "checks the revision of the original payment's group", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      result =
        submit_one(conn, reduce_operation(%{"expected_revision" => 99}))

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["expected_revision"] == 99
      assert result["actual_revision"] == 2

      result =
        submit_one(
          conn,
          reduce_operation(%{"operation_id" => "op-reduce-2", "expected_revision" => 2})
        )

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end

    test "is durably idempotent, and the original payment still answers retries verbatim", %{
      conn: conn
    } do
      open_group!(conn)

      original_payment =
        pay!(conn, "op-pay", "group-81", 10000)

      original_reduction = submit_one(conn, reduce_operation())

      # retrying the reduction returns the stored result and reduces nothing
      assert submit_one(conn, reduce_operation()) == original_reduction
      assert ledger(conn)["cash_reduced_cents"] == 4000

      # retrying the original payment returns its exact original result even
      # though the group's current state differs
      assert submit_one(conn, %{
               "operation_id" => "op-pay",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "group-81",
               "amount_cents" => 10000
             }) == original_payment

      assert get_group(conn, "group-81")["cash_paid_cents"] == 6000
    end
  end

  describe "charge_back_payment" do
    test "removes held cash from an active group and reopens the deposit", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      assert submit_one(conn, charge_back_operation()) == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 3
             }

      data = get_group(conn, "group-81")
      assert data["status"] == "active"
      assert data["cash_paid_cents"] == 0
      assert room(data, "room-a")["cash_paid_cents"] == 0

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10000

      # a second chargeback of the same payment is rejected
      result =
        submit_one(conn, charge_back_operation(%{"operation_id" => "op-chargeback-2"}))

      assert result["code"] == "payment_not_chargeable"
    end

    test "reclassifies refunded cash of a cancelled group without touching the guest refund", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)
      cancel_group!(conn, "op-cancel", "group-81", "2026-11-26")

      result = submit_one(conn, charge_back_operation())

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10000
      assert result["outstanding_deposit_cents"] == 0

      # the ledger classification changes: refunded becomes charged-back
      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10000

      # the original payment's group still increments its revision, once,
      # even though it is cancelled
      data = get_group(conn, "group-81")
      assert data["status"] == "cancelled"
      assert data["revision"] == 4
    end

    test "reclassifies retained cash of a non-refundable cancellation", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)
      cancel_group!(conn, "op-cancel", "group-81", "2026-12-08")

      result = submit_one(conn, charge_back_operation())

      assert result["charged_back_cents"] == 10000

      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10000
    end

    test "excludes the portion already recorded as reduced", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)
      submit_one(conn, reduce_operation())

      result = submit_one(conn, charge_back_operation())

      assert result["charged_back_cents"] == 6000

      assert conn |> get_payment("op-pay") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 4000,
                 "charged_back_cents" => 6000
               }
             }
    end

    test "revokes the credit entitlement the converted cash created", %{conn: conn} do
      issue_credit!(conn, "group-81", 10000)

      result =
        submit_one(conn, charge_back_operation(%{"payment_operation_id" => "op-pay-group-81"}))

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10000

      # the 11000 entitlement is revoked from the lot's remaining balance
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10000
    end

    test "entitlements telescope across the payments funding one lot", %{conn: conn} do
      # one night; room-a due 5005, room-b due 5000
      open_group!(conn, %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 25025},
          %{"room_id" => "room-b", "nightly_rate_cents" => 25000}
        ]
      })

      pay!(conn, "op-pay-1", "group-81", 5005)
      pay!(conn, "op-pay-2", "group-81", 5000)
      cancel_group!(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")

      # combined cash 10005, lot 11006; entitlements: through op-pay-1 the
      # bonus value is 5005 + 501 = 5506; through op-pay-2 it is
      # 10005 + 1001 = 11006, so op-pay-2's entitlement is 5500
      result =
        submit_one(conn, charge_back_operation(%{"payment_operation_id" => "op-pay-2"}))

      assert result["charged_back_cents"] == 5000

      # op-pay-2's 5500 entitlement is revoked; op-pay-1's 5506 remains
      assert guest_credit(conn, "guest-22")["available_cents"] == 5506

      assert conn |> get_payment("op-pay-2") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-2",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 5000
               }
             }
    end

    test "an unrecoverable clawback shortfalls credit from the lot applied to active groups", %{
      conn: conn
    } do
      # room-a due 5005, room-b due 5000
      open_group!(conn, %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 25025},
          %{"room_id" => "room-b", "nightly_rate_cents" => 25000}
        ]
      })

      pay!(conn, "op-pay-1", "group-81", 5005)
      pay!(conn, "op-pay-2", "group-81", 5000)
      cancel_group!(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")

      # the lot is 11006; spend 6000 of it into an active group
      open_group!(conn, %{
        "operation_id" => "op-open-100",
        "group_id" => "group-100",
        "arrival_on" => "2027-01-10",
        "departure_on" => "2027-01-12",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      })

      apply_result =
        submit_one(conn, %{
          "operation_id" => "op-apply-100",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-100",
          "amount_cents" => 6000
        })

      assert apply_result["status"] == "applied"
      group_100_revision_before = get_group(conn, "group-100")["revision"]

      # charging back op-pay-1 revokes its 5506 entitlement: 5006 remains on
      # the lot, so 500 cannot be recovered
      result =
        submit_one(conn, charge_back_operation(%{"payment_operation_id" => "op-pay-1"}))

      assert result["charged_back_cents"] == 5005

      # the group funded by the affected credit is not touched
      assert get_group(conn, "group-100")["revision"] == group_100_revision_before
      assert get_group(conn, "group-100")["credit_paid_cents"] == 6000

      assert ledger(conn)["credit_shortfall_cents"] == 500
      # the liability still covers the applied 6000, including the
      # shortfall-covered credit
      assert ledger(conn)["credit_liability_cents"] == 6000
      assert ledger(conn)["cash_converted_to_credit_cents"] == 5000

      # a refundable cancellation of group-100 returns 6000 to the
      # shortfalled lot: it extinguishes the 500 clawback before 5500 becomes
      # available again
      cancel_group!(conn, "op-cancel-100", "group-100", "2026-12-20")

      assert guest_credit(conn, "guest-22", "2026-12-20")["available_cents"] == 5500
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 5500
    end

    test "non-refundable consumption of the applied credit reduces the shortfall", %{conn: conn} do
      open_group!(conn, %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 25025},
          %{"room_id" => "room-b", "nightly_rate_cents" => 25000}
        ]
      })

      pay!(conn, "op-pay-1", "group-81", 5005)
      pay!(conn, "op-pay-2", "group-81", 5000)
      cancel_group!(conn, "op-cancel", "group-81", "2026-11-26", "hotel_credit")

      open_group!(conn, %{
        "operation_id" => "op-open-100",
        "group_id" => "group-100",
        "arrival_on" => "2027-01-10",
        "departure_on" => "2027-01-12",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      })

      submit_one(conn, %{
        "operation_id" => "op-apply-100",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-100",
        "amount_cents" => 6000
      })

      submit_one(conn, charge_back_operation(%{"payment_operation_id" => "op-pay-1"}))

      assert ledger(conn)["credit_shortfall_cents"] == 500

      # 8 days before arrival: non-refundable; the applied credit is consumed
      cancel_group!(conn, "op-cancel-100", "group-100", "2027-01-02")

      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
      assert guest_credit(conn, "guest-22", "2027-01-02")["available_cents"] == 0
    end

    test "rejects unknown, non-payment, rejected, and exhausted payment targets", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      result = submit_one(conn, charge_back_operation(%{"payment_operation_id" => "op-unknown"}))
      assert result["code"] == "operation_not_found"

      result =
        submit_one(
          conn,
          charge_back_operation(%{
            "operation_id" => "op-chargeback-open",
            "payment_operation_id" => "op-open"
          })
        )

      assert result["code"] == "payment_not_chargeable"

      submit_one(conn, %{
        "operation_id" => "op-pay-rejected",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 99_999_999
      })

      result =
        submit_one(
          conn,
          charge_back_operation(%{
            "operation_id" => "op-chargeback-rejected",
            "payment_operation_id" => "op-pay-rejected"
          })
        )

      assert result["code"] == "payment_not_chargeable"

      # a fully reduced payment has nothing left to charge back
      submit_one(conn, reduce_operation(%{"amount_cents" => 10000}))

      result =
        submit_one(
          conn,
          charge_back_operation(%{
            "operation_id" => "op-chargeback-exhausted",
            "payment_operation_id" => "op-pay"
          })
        )

      assert result["code"] == "payment_not_chargeable"
    end

    test "checks the revision of the original payment's group", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      result = submit_one(conn, charge_back_operation(%{"expected_revision" => 1}))
      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["actual_revision"] == 2

      result =
        submit_one(
          conn,
          charge_back_operation(%{"operation_id" => "op-chargeback-2", "expected_revision" => 2})
        )

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end

    test "is durably idempotent and never rewrites the payment's stored result", %{conn: conn} do
      open_group!(conn)

      original_payment = pay!(conn, "op-pay", "group-81", 10000)
      original_chargeback = submit_one(conn, charge_back_operation())

      assert submit_one(conn, charge_back_operation()) == original_chargeback
      assert ledger(conn)["cash_charged_back_cents"] == 10000

      assert submit_one(conn, %{
               "operation_id" => "op-pay",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "group-81",
               "amount_cents" => 10000
             }) == original_payment

      assert get_group(conn, "group-81")["cash_paid_cents"] == 0
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns the current disposition of an untouched payment", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      assert conn |> get_payment("op-pay") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 10000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end

    test "an unknown payment returns 404", %{conn: conn} do
      assert conn
             |> get_payment("op-unknown")
             |> json_response(404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "a non-payment record or rejected payment returns 422", %{conn: conn} do
      open_group!(conn)

      assert conn
             |> get_payment("op-open")
             |> json_response(422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      submit_one(conn, %{
        "operation_id" => "op-pay-rejected",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-missing",
        "amount_cents" => 100
      })

      assert conn
             |> get_payment("op-pay-rejected")
             |> json_response(422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    test "dispositions follow the payment through settlement and agree with the ledger", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      # refundable room cancellation refunds 1000 of this payment
      submit_one(conn, %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-b"]
      })

      submit_one(conn, reduce_operation(%{"amount_cents" => 1500}))

      %{"data" => statement} = get_payment(conn, "op-pay") |> json_response(200)

      assert statement["held_cents"] == 7500
      assert statement["refunded_cents"] == 1000
      assert statement["reduced_cents"] == 1500

      dispositions =
        for field <-
              ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
            do: statement[field]

      assert Enum.sum(dispositions) == statement["recorded_cents"]

      assert ledger(conn)["cash_held_cents"] == statement["held_cents"]
      assert ledger(conn)["cash_refunded_cents"] == statement["refunded_cents"]
      assert ledger(conn)["cash_reduced_cents"] == statement["reduced_cents"]
    end
  end
end
