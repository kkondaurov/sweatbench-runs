defmodule GroupStayWeb.PaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 19_500
      },
      overrides
    )
  end

  defp reduce_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp chargeback_op(overrides \\ %{}) do
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

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)["data"]
  end

  defp get_ledger(query \\ "") do
    conn = get(build_conn(), "/api/v1/ledger" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_credit(guest_id, query \\ "") do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_payment(payment_operation_id) do
    get(build_conn(), ~p"/api/v1/payments/#{payment_operation_id}")
  end

  # Opens, funds, and cancels a flexible group for the guest into a hotel
  # credit lot of `cash_cents` + 10%.
  defp issue_credit(conn, guest_id, group_id, cash_cents) do
    operations = [
      open_op(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "guest_id" => guest_id
      }),
      payment_op(%{
        "operation_id" => "op-pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})
    assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"amount_cents" => 4_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 4_000,
               "revision" => 3
             }

      group = get_group("group-81")

      # the payment filled room-a then room-b, so room-b is reduced first
      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 6_500}
             ] = group["rooms"]

      assert group["outstanding_deposit_cents"] == 4_000

      assert %{"cash_held_cents" => 15_500, "cash_reduced_cents" => 4_000} = get_ledger()
    end

    test "removes only the target payment's allocations", %{conn: conn} do
      operations = [
        open_op(),
        # payment 1 fills room-a; payment 2 fills room-b
        payment_op(%{"amount_cents" => 9_000}),
        payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 10_500}),
        reduce_op(%{"payment_operation_id" => "op-pay-2", "amount_cents" => 4_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 4_000

      group = get_group("group-81")

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 6_500}
             ] = group["rooms"]

      # payment 1 is untouched
      conn = get_payment("op-pay")

      assert %{"data" => %{"held_cents" => 9_000, "reduced_cents" => 0}} =
               json_response(conn, 200)

      conn = get_payment("op-pay-2")

      assert %{"data" => %{"held_cents" => 6_500, "reduced_cents" => 4_000}} =
               json_response(conn, 200)
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"amount_cents" => 4_000}),
        reduce_op(%{"operation_id" => "op-reduce-2", "amount_cents" => 500}),
        # the complete remaining held portion is valid
        reduce_op(%{"operation_id" => "op-reduce-3", "amount_cents" => 15_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["status"]) == List.duplicate("applied", 5)

      group = get_group("group-81")
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]
      assert group["outstanding_deposit_cents"] == 19_500

      assert %{"cash_reduced_cents" => 19_500, "cash_held_cents" => 0} = get_ledger()

      # nothing held anymore: the payment can never accept another reduction
      conn =
        post_batch(build_conn(), %{
          "operations" => [reduce_op(%{"operation_id" => "op-reduce-4"})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects an unknown payment operation", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [reduce_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "operation_not_found"
             }
    end

    test "rejects targets that can never accept a positive reduction", %{conn: conn} do
      operations = [
        open_op(),
        # a non-payment operation
        reduce_op(%{"payment_operation_id" => "op-open", "operation_id" => "op-1"}),
        # a rejected payment
        payment_op(%{"operation_id" => "op-rejected", "amount_cents" => 19_501}),
        reduce_op(%{"payment_operation_id" => "op-rejected", "operation_id" => "op-2"}),
        # a rejected payment whose group never existed
        payment_op(%{
          "operation_id" => "op-rejected-missing",
          "group_id" => "group-missing"
        }),
        reduce_op(%{"payment_operation_id" => "op-rejected-missing", "operation_id" => "op-3"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, first, _, second, _, third]} = json_response(conn, 200)
      assert first["code"] == "payment_not_reducible"
      assert first["group_id"] == "group-81"
      assert second["code"] == "payment_not_reducible"
      assert third["code"] == "payment_not_reducible"
    end

    test "rejects a payment with no held cash remaining", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81"
        },
        reduce_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects non-positive and excessive amounts", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"operation_id" => "op-1", "amount_cents" => 0}),
        reduce_op(%{"operation_id" => "op-2", "amount_cents" => -100}),
        reduce_op(%{"operation_id" => "op-3", "amount_cents" => "1000"}),
        reduce_op(%{"operation_id" => "op-4", "amount_cents" => 19_501})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, zero, negative, string, excessive]} = json_response(conn, 200)
      assert zero["code"] == "invalid_amount"
      assert negative["code"] == "invalid_amount"
      assert string["code"] == "invalid_amount"
      assert excessive["code"] == "reduction_exceeds_held_cash"

      assert %{"cash_reduced_cents" => 0, "cash_held_cents" => 19_500} = get_ledger()
    end

    test "checks the revision of the original payment's group", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"expected_revision" => 1})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "reduces only the cash still held after a partial settlement", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "room_ids" => ["room-b"]
        },
        reduce_op(%{"amount_cents" => 5_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 5_000

      # room-a keeps 4_000 held; room-b's 10_500 was refunded earlier
      group = get_group("group-81")
      assert [%{"cash_paid_cents" => 4_000}, %{"cash_paid_cents" => 0}] = group["rooms"]

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 4_000,
                 "refunded_cents" => 10_500,
                 "reduced_cents" => 5_000
               }
             } = json_response(conn, 200)
    end

    test "is durably idempotent", %{conn: conn} do
      operations = [open_op(), payment_op(), reduce_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => [reduce_op()]})
      assert %{"results" => [retry]} = json_response(conn, 200)
      assert retry == result

      assert %{"cash_reduced_cents" => 1_000} = get_ledger()

      # a different amount under the same identifier conflicts
      conn =
        post_batch(build_conn(), %{"operations" => [reduce_op(%{"amount_cents" => 2_000})]})

      assert %{"results" => [conflict]} = json_response(conn, 200)
      assert conflict["code"] == "operation_id_conflict"
    end

    test "retrying the original payment returns its original result after a reduction", %{
      conn: conn
    } do
      operations = [open_op(), payment_op(), reduce_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, payment, _]} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => [payment_op()]})
      assert %{"results" => [retry]} = json_response(conn, 200)

      # the stored result is verbatim even though the group state now differs
      assert retry == payment
      assert retry["outstanding_deposit_cents"] == 0
    end
  end

  describe "charge_back_payment" do
    test "removes held cash and reopens the outstanding deposit", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        chargeback_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      group = get_group("group-81")
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000} = get_ledger()
    end

    test "removes only the target payment's held cash", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 9_000}),
        payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 10_500}),
        chargeback_op(%{"payment_operation_id" => "op-pay-2"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_500
      assert result["outstanding_deposit_cents"] == 10_500

      group = get_group("group-81")

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = group["rooms"]

      conn = get_payment("op-pay")

      assert %{"data" => %{"held_cents" => 9_000, "charged_back_cents" => 0}} =
               json_response(conn, 200)
    end

    test "moves refunded cash to charged-back without reissuing anything", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81"
        },
        chargeback_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_000
      assert result["outstanding_deposit_cents"] == 0
      # the cancelled group's revision still increments exactly once
      assert result["revision"] == 4

      assert %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 10_000} = get_ledger()

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "charged_back_cents" => 10_000
               }
             } = json_response(conn, 200)
    end

    test "moves retained cash to charged-back", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        # inside the flex-14 window: retained
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81"
        },
        chargeback_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["charged_back_cents"] == 10_000

      assert %{"cash_retained_cents" => 0, "cash_charged_back_cents" => 10_000} = get_ledger()
    end

    test "revokes the credit entitlement created by converted cash", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "refund_method" => "hotel_credit"
        },
        chargeback_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_000

      # the unspent 11_000 entitlement is revoked and the liability ends
      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = get_ledger()

      assert get_credit("guest-22")["available_cents"] == 0

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "converted_to_credit_cents" => 0,
                 "charged_back_cents" => 10_000
               }
             } = json_response(conn, 200)
    end

    test "leaves reduced portions reduced and charges back the rest", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"amount_cents" => 5_000}),
        chargeback_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 14_500

      assert %{
               "cash_reduced_cents" => 5_000,
               "cash_charged_back_cents" => 14_500,
               "cash_held_cents" => 0
             } = get_ledger()

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "recorded_cents" => 19_500,
                 "held_cents" => 0,
                 "reduced_cents" => 5_000,
                 "charged_back_cents" => 14_500
               }
             } = json_response(conn, 200)
    end

    test "spends entitlement from the lot balance first and tracks the shortfall", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(%{
          "operation_id" => "op-open-82",
          "group_id" => "group-82",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
        }),
        %{
          "operation_id" => "op-credit-82",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-22",
          "group_id" => "group-82",
          "amount_cents" => 4_000
        },
        chargeback_op(%{"payment_operation_id" => "op-pay-group-91"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 10_000
      assert result["group_id"] == "group-91"

      # the 11_000 entitlement removes the 7_000 unspent balance; the 4_000
      # still applied to group-82 becomes unrecovered clawback and shortfall
      assert %{
               "credit_liability_cents" => 4_000,
               "credit_shortfall_cents" => 4_000
             } = get_ledger()

      assert get_credit("guest-22")["available_cents"] == 0

      # the group funded by the affected credit is untouched
      group = get_group("group-82")
      assert group["revision"] == 2
      assert group["credit_paid_cents"] == 4_000
      assert group["status"] == "active"
    end

    test "a later restoration extinguishes the unrecovered clawback", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(%{
          "operation_id" => "op-open-82",
          "group_id" => "group-82",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
        }),
        %{
          "operation_id" => "op-credit-82",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-22",
          "group_id" => "group-82",
          "amount_cents" => 4_000
        },
        chargeback_op(%{"payment_operation_id" => "op-pay-group-91"}),
        # refundable cancellation returns the 4_000 of credit to the lot,
        # where it is absorbed by the 4_000 of unrecovered clawback
        %{
          "operation_id" => "op-cancel-82",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-82"
        }
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"

      assert %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = get_ledger()

      assert get_credit("guest-22")["available_cents"] == 0
    end

    test "a non-refundable settlement of the credit reduces the shortfall", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(%{
          "operation_id" => "op-open-82",
          "group_id" => "group-82",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
        }),
        %{
          "operation_id" => "op-credit-82",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-22",
          "group_id" => "group-82",
          "amount_cents" => 4_000
        },
        chargeback_op(%{"payment_operation_id" => "op-pay-group-91"}),
        # 2 days before arrival: non-refundable, so the credit is consumed
        %{
          "operation_id" => "op-cancel-82",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-27",
          "group_id" => "group-82"
        }
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"

      assert %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = get_ledger()
    end

    test "assigns entitlements in funding order and telescopes to the lot", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 9_500}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "refund_method" => "hotel_credit"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, cancel]} = json_response(conn, 200)
      # 19_500 + 1_950 bonus
      assert cancel["credit_issued_cents"] == 21_450

      # entitlement of op-pay: credit_value(10_000) = 11_000
      # entitlement of op-pay-2: credit_value(19_500) - credit_value(10_000) = 10_450
      conn =
        post_batch(build_conn(), %{
          "operations" => [chargeback_op(%{"payment_operation_id" => "op-pay"})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["charged_back_cents"] == 10_000

      # 21_450 - 11_000 revoked; op-pay-2's 10_450 entitlement remains
      assert %{"credit_liability_cents" => 10_450} = get_ledger()

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            chargeback_op(%{
              "operation_id" => "op-chargeback-2",
              "payment_operation_id" => "op-pay-2"
            })
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["charged_back_cents"] == 9_500
      assert %{"credit_liability_cents" => 0} = get_ledger()
    end

    test "claws back entitlements independently per lot", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        %{
          "operation_id" => "op-cancel-a",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "op-cancel-b",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-21",
          "group_id" => "group-81",
          "room_ids" => ["room-b"],
          "refund_method" => "hotel_credit"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, first, second]} = json_response(conn, 200)
      assert first["credit_issued_cents"] == 9_900
      assert second["credit_issued_cents"] == 11_550

      conn =
        post_batch(build_conn(), %{"operations" => [chargeback_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["charged_back_cents"] == 19_500

      # both lots are fully revoked
      assert %{
               "credit_liability_cents" => 0,
               "cash_charged_back_cents" => 19_500
             } = get_ledger()
    end

    test "rejects an unknown payment operation", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [chargeback_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "rejected",
               "code" => "operation_not_found"
             }
    end

    test "rejects payments that are not chargeable", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        # a non-payment operation
        chargeback_op(%{"payment_operation_id" => "op-open", "operation_id" => "op-1"}),
        # a rejected payment whose group never existed
        payment_op(%{
          "operation_id" => "op-rejected-missing",
          "group_id" => "group-missing"
        }),
        chargeback_op(%{
          "payment_operation_id" => "op-rejected-missing",
          "operation_id" => "op-2"
        }),
        # already charged back
        chargeback_op(),
        chargeback_op(%{"operation_id" => "op-3"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, first, _, second, _, third]} = json_response(conn, 200)
      assert first["code"] == "payment_not_chargeable"
      assert first["group_id"] == "group-81"
      assert second["code"] == "payment_not_chargeable"
      assert third["code"] == "payment_not_chargeable"
    end

    test "rejects a fully reduced payment", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"amount_cents" => 19_500}),
        chargeback_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["code"] == "payment_not_chargeable"
    end

    test "checks the revision of the original payment's group", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        chargeback_op(%{"expected_revision" => 1})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "is durably idempotent", %{conn: conn} do
      operations = [open_op(), payment_op(), chargeback_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => [chargeback_op()]})
      assert %{"results" => [retry]} = json_response(conn, 200)
      assert retry == result

      assert %{"cash_charged_back_cents" => 19_500} = get_ledger()
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reconciles every cent of a payment through its lifecycle", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        reduce_op(%{"amount_cents" => 1_500}),
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "room_ids" => ["room-b"]
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _]} = json_response(conn, 200)

      conn = get_payment("op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 19_500,
                 "held_cents" => 9_000,
                 "refunded_cents" => 9_000,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1_500,
                 "charged_back_cents" => 0
               }
             }
    end

    test "reports zeros for a payment that is entirely held", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op(), payment_op()]})
      assert %{"results" => [_, _]} = json_response(conn, 200)

      conn = get_payment("op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 19_500,
                 "held_cents" => 19_500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end

    test "returns 404 when no durable record exists", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/payments/op-unknown")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 for records that are not applied cash payments", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"operation_id" => "op-rejected", "amount_cents" => 19_501})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _]} = json_response(conn, 200)

      # an applied non-payment operation
      conn = get_payment("op-open")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      # a rejected payment
      conn = get_payment("op-rejected")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end
end
