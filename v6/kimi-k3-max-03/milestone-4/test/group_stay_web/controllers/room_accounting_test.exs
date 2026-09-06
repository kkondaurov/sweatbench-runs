defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  alias GroupStay.Repo

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp apply_ops(operations) do
    conn = post_batch(operations)
    assert %{"results" => results} = json_response(conn, 200)
    results
  end

  defp apply_ops!(operations) do
    results = apply_ops(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    results
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)
  end

  defp get_ledger do
    conn = get(build_conn(), ~p"/api/v1/ledger")
    json_response(conn, 200)
  end

  defp get_credit(guest_id) do
    conn = get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit")
    json_response(conn, 200)
  end

  defp get_payment(payment_operation_id) do
    get(build_conn(), ~p"/api/v1/payments/#{payment_operation_id}")
  end

  # The default group has two rooms over three nights: room-a at 15_000
  # (deposit 9_000) and room-b at 17_500 (deposit 10_500).
  describe "room-level accounting" do
    test "group responses expose per-room accounting fields" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      assert %{
               "data" => %{
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "active",
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 9_000,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "active",
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 1_000,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = get_group("group-81")
    end

    test "cash fills one room's deposit before moving to the next" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000}),
        record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 10_500})
      ])

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 19_500,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 10_500}
                 ]
               }
             } = get_group("group-81")
    end

    test "unpaid deposit for cancelled rooms ceases to be due" do
      apply_ops!([open_group_op()])

      conn = post_batch([cancel_rooms_op(%{"room_ids" => ["room-b"]})])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "outstanding_deposit_cents" => 9_000,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "active"},
                   %{"room_id" => "room-b", "status" => "cancelled"}
                 ]
               }
             } = get_group("group-81")
    end

    test "later funding fills only the active rooms" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_500}),
        cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})
      ])

      # room-b was refunded its 500; room-a still holds 9_000 of cash.
      assert %{"data" => %{"outstanding_deposit_cents" => 0}} = get_group("group-81")

      conn =
        post_batch([
          record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1})
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}]
             } = json_response(conn, 200)
    end

    test "credit funds rooms in the same original order" do
      # Issue an 11_000 lot, then apply 5_000 of it to the group.
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 5_000})
      ])

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "credit_paid_cents" => 5_000},
                   %{"room_id" => "room-b", "credit_paid_cents" => 0}
                 ],
                 "credit_paid_cents" => 5_000
               }
             } = get_group("group-82")
    end

    test "group totals are the sums of the active rooms" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})
      ])

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 45_000,
                 "deposit_due_cents" => 9_000,
                 "deposit_paid_cents" => 9_000,
                 "cash_paid_cents" => 9_000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             } = get_group("group-81")
    end
  end

  describe "cancel_rooms" do
    test "settles the selected room's cash with the same rules as full cancellation" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "cancelled_room_ids" => ["room-b"],
                   "refunded_cents" => 1_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"cash_held_cents" => 9_000, "cash_refunded_cents" => 1_000}} =
               get_ledger()
    end

    test "returns cancelled_room_ids in the group's original room order" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          cancel_rooms_op(%{"room_ids" => ["room-b", "room-a"], "occurred_on" => "2026-11-20"})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "cancelled_room_ids" => ["room-a", "room-b"],
                   "refunded_cents" => 10_000
                 }
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"status" => "cancelled"}} = get_group("group-81")
    end

    test "rejects duplicate, unknown, or inactive room identifiers" do
      apply_ops!([open_group_op()])

      for {room_ids, index} <-
            Enum.with_index([
              ["room-a", "room-a"],
              ["room-missing"],
              ["room-a", "room-missing"],
              []
            ]) do
        conn =
          post_batch([
            cancel_rooms_op(%{"operation_id" => "op-cr-#{index}", "room_ids" => room_ids})
          ])

        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
                 json_response(conn, 200)
      end

      # A cancelled room is not a valid selection either.
      apply_ops!([cancel_rooms_op(%{"room_ids" => ["room-a"]})])

      conn =
        post_batch([
          cancel_rooms_op(%{"operation_id" => "op-cr-again", "room_ids" => ["room-a"]})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
               json_response(conn, 200)
    end

    test "the hotel-credit bonus is computed once on the selected rooms' combined cash" do
      # Two rooms at 525 each for one night: deposits 105 and 105, combined
      # 210 -> bonus 21 -> issued 231. Per-room bonuses would sum to 232.
      apply_ops!([
        open_group_op(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 525},
            %{"room_id" => "room-b", "nightly_rate_cents" => 525}
          ]
        }),
        record_cash_payment_op(%{"amount_cents" => 210})
      ])

      conn =
        post_batch([
          cancel_rooms_op(%{
            "room_ids" => ["room-a", "room-b"],
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 231
                 }
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"available_cents" => 231}} = get_credit("guest-22")
    end

    test "a non-refundable partial cancellation retains the selected rooms' cash" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-12-01"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 1_000}
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"cash_retained_cents" => 1_000}} = get_ledger()
    end

    test "hotel credit is rejected for a non-refundable partial cancellation" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          cancel_rooms_op(%{
            "room_ids" => ["room-a"],
            "occurred_on" => "2026-12-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "refund_method_not_available"}]
             } = json_response(conn, 200)

      assert %{"data" => %{"revision" => 2, "status" => "active"}} = get_group("group-81")
    end

    test "cancel_group now settles only the remaining active rooms" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-20"})
      ])

      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-11-21"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 1_000,
                   "retained_cents" => 0,
                   "revision" => 4
                 } = result
               ]
             } = json_response(conn, 200)

      # The full-cancellation contract is unchanged: no cancelled_room_ids.
      refute Map.has_key?(result, "cancelled_room_ids")

      assert %{"data" => %{"status" => "cancelled"}} = get_group("group-81")
      assert %{"data" => %{"cash_refunded_cents" => 10_000}} = get_ledger()
    end

    test "applied credit on cancelled rooms is restored or consumed per the same rules" do
      # Issue a 11_000 lot, then fund a group partly with credit.
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 9_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 1_000
        })
      ])

      conn =
        post_batch([
          cancel_rooms_op(%{
            "group_id" => "group-82",
            "room_ids" => ["room-a"],
            "occurred_on" => "2026-11-20"
          })
        ])

      # room-a held only credit (9_000), so no cash is refunded.
      assert %{"results" => [%{"status" => "applied", "refunded_cents" => 0}]} =
               json_response(conn, 200)

      # room-a's 9_000 of credit returns to its lot.
      assert %{"data" => %{"available_cents" => 11_000}} = get_credit("guest-22")
    end

    test "cancel_rooms is durably idempotent" do
      ops = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})
      ]

      conn = post_batch(ops)
      assert %{"results" => results} = json_response(conn, 200)

      conn = post_batch(ops)
      assert %{"results" => ^results} = json_response(conn, 200)

      assert %{"data" => %{"revision" => 3}} = get_group("group-81")
    end

    test "expected_revision is honored before other validation" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          cancel_rooms_op(%{"room_ids" => ["room-missing"], "expected_revision" => 9})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 9,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end
  end

  describe "reduce_cash_payment" do
    test "removes held allocations in reverse fill order and reopens the outstanding deposit" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn = post_batch([reduce_cash_payment_op(%{"amount_cents" => 4_000})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "amount_cents" => 4_000,
                   "outstanding_deposit_cents" => 13_500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      # Reverse fill order: room-b (1_000 held) empties first, then room-a.
      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 6_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = get_group("group-81")

      assert %{"data" => %{"cash_held_cents" => 6_000, "cash_reduced_cents" => 4_000}} =
               get_ledger()
    end

    test "successive reductions compose against the remaining held cash" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        reduce_cash_payment_op(%{"amount_cents" => 4_000})
      ])

      conn =
        post_batch([
          reduce_cash_payment_op(%{"operation_id" => "op-reduce-2", "amount_cents" => 6_000})
        ])

      assert %{"results" => [%{"status" => "applied", "outstanding_deposit_cents" => 19_500}]} =
               json_response(conn, 200)

      conn =
        post_batch([
          reduce_cash_payment_op(%{"operation_id" => "op-reduce-3", "amount_cents" => 1})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_reducible"}]} =
               json_response(conn, 200)
    end

    test "rejects without a durable record, on a non-payment record, or a rejected payment" do
      conn = post_batch([reduce_cash_payment_op(%{"payment_operation_id" => "op-missing"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_not_found"}]} =
               json_response(conn, 200)

      apply_ops!([open_group_op()])

      conn =
        post_batch([
          reduce_cash_payment_op(%{
            "operation_id" => "op-reduce-a",
            "payment_operation_id" => "op-open"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_reducible"}]} =
               json_response(conn, 200)

      apply_ops([record_cash_payment_op(%{"amount_cents" => 19_501})])

      conn =
        post_batch([
          reduce_cash_payment_op(%{"operation_id" => "op-reduce-b", "amount_cents" => 100})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_reducible"}]} =
               json_response(conn, 200)
    end

    test "rejects a non-positive amount and an amount above the held cash" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn = post_batch([reduce_cash_payment_op(%{"amount_cents" => 0})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_amount"}]} =
               json_response(conn, 200)

      conn =
        post_batch([
          reduce_cash_payment_op(%{"operation_id" => "op-reduce-2", "amount_cents" => 10_001})
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}]
             } = json_response(conn, 200)
    end

    test "reduction is rejected with payment_not_reducible when no held cash remains" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20"})
      ])

      conn = post_batch([reduce_cash_payment_op(%{"amount_cents" => 100})])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_reducible"}]} =
               json_response(conn, 200)
    end

    test "a reduction targets only the payment's still-held cash" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})
      ])

      # room-b's 1_000 is refunded; the payment's held cash is room-a's 9_000.
      conn = post_batch([reduce_cash_payment_op(%{"amount_cents" => 4_000})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "amount_cents" => 4_000,
                   "outstanding_deposit_cents" => 4_000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "recorded_cents" => 10_000,
                 "held_cents" => 5_000,
                 "refunded_cents" => 1_000,
                 "reduced_cents" => 4_000,
                 "charged_back_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "checks expected_revision against the original payment's group" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          reduce_cash_payment_op(%{"amount_cents" => 100, "expected_revision" => 1})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "reductions are durably idempotent and the original payment replay is exact" do
      ops = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        reduce_cash_payment_op(%{"amount_cents" => 4_000})
      ]

      conn = post_batch(ops)
      assert %{"results" => results} = json_response(conn, 200)

      conn = post_batch(ops)
      assert %{"results" => ^results} = json_response(conn, 200)

      # The payment was reduced exactly once.
      assert %{"data" => %{"cash_reduced_cents" => 4_000, "cash_held_cents" => 6_000}} =
               get_ledger()

      # Retrying the original payment still returns its original result.
      conn = post_batch([open_group_op(), record_cash_payment_op(%{"amount_cents" => 10_000})])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "status" => "applied",
                   "amount_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      # The retry did not reapply cash: held stays at the post-reduction 6_000.
      assert %{"data" => %{"cash_held_cents" => 6_000, "cash_reduced_cents" => 4_000}} =
               get_ledger()
    end
  end

  describe "charge_back_payment" do
    test "reverses all held cash of a payment and reopens the active rooms' outstanding deposit" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn = post_batch([charge_back_payment_op()])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "charged_back_cents" => 10_000,
                   "outstanding_deposit_cents" => 19_500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000}
             } = get_ledger()
    end

    test "moves refunded and retained portions to charged-back cash" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20"})
      ])

      assert %{"data" => %{"cash_refunded_cents" => 10_000}} = get_ledger()

      conn = post_batch([charge_back_payment_op()])

      assert %{
               "results" => [
                 %{"status" => "applied", "charged_back_cents" => 10_000, "revision" => 4}
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 10_000
               }
             } = get_ledger()

      # Retained history reclassifies the same way.
      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 1_000
        }),
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-01"
        })
      ])

      conn =
        post_batch([
          charge_back_payment_op(%{
            "operation_id" => "op-cb-2",
            "payment_operation_id" => "op-pay-2"
          })
        ])

      assert %{"results" => [%{"status" => "applied", "charged_back_cents" => 1_000}]} =
               json_response(conn, 200)

      assert %{"data" => %{"cash_retained_cents" => 0}} = get_ledger()
    end

    test "rejects when already charged back, fully reduced, or not an applied payment" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          charge_back_payment_op(%{
            "operation_id" => "op-cb-open",
            "payment_operation_id" => "op-open"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_chargeable"}]} =
               json_response(conn, 200)

      apply_ops!([charge_back_payment_op()])

      conn =
        post_batch([
          charge_back_payment_op(%{"operation_id" => "op-cb-2"})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_chargeable"}]} =
               json_response(conn, 200)

      # Fully reduced payments cannot be charged back.
      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-3",
          "group_id" => "group-83",
          "amount_cents" => 1_000
        }),
        reduce_cash_payment_op(%{
          "operation_id" => "op-reduce-3",
          "payment_operation_id" => "op-pay-3",
          "amount_cents" => 1_000
        })
      ])

      conn =
        post_batch([
          charge_back_payment_op(%{
            "operation_id" => "op-cb-3",
            "payment_operation_id" => "op-pay-3"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_chargeable"}]} =
               json_response(conn, 200)

      conn =
        post_batch([
          charge_back_payment_op(%{
            "operation_id" => "op-cb-4",
            "payment_operation_id" => "op-missing"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_not_found"}]} =
               json_response(conn, 200)
    end

    test "a payment can be charged back whether its group is active or cancelled" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      conn = post_batch([charge_back_payment_op()])

      assert %{
               "results" => [
                 %{"status" => "applied", "charged_back_cents" => 10_000, "revision" => 4}
               ]
             } = json_response(conn, 200)
    end

    test "revoking entitlement removes it from the lot's balance first" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      # The lot is worth 11_000; the entitlement is 11_000, fully removable.
      assert %{"data" => %{"available_cents" => 11_000}} = get_credit("guest-22")

      apply_ops!([charge_back_payment_op()])

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit("guest-22")

      assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
               get_ledger()
    end

    test "entitlement that cannot be removed becomes the lot's unrecovered clawback" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 5_000})
      ])

      # 11_000 entitlement, only 6_000 remaining: 6_000 is removed, 5_000 is
      # clawback; the 5_000 still applied to group-82 makes the shortfall.
      apply_ops!([charge_back_payment_op()])

      assert %{
               "data" => %{
                 "credit_liability_cents" => 5_000,
                 "credit_shortfall_cents" => 5_000,
                 "cash_charged_back_cents" => 10_000
               }
             } = get_ledger()

      # The chargeback touches only the original payment's group.
      assert %{"data" => %{"revision" => 4}} = get_group("group-81")
      assert %{"data" => %{"revision" => 2, "status" => "active"}} = get_group("group-82")
    end

    test "non-refundable settlement of the applied credit reduces the shortfall" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 5_000}),
        charge_back_payment_op()
      ])

      assert %{"data" => %{"credit_shortfall_cents" => 5_000}} = get_ledger()

      apply_ops!([
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-01"
        })
      ])

      assert %{
               "data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}
             } = get_ledger()
    end

    test "credit returning to a shortfalled lot extinguishes the clawback first" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 5_000}),
        charge_back_payment_op()
      ])

      # Refundable cancellation of group-82 returns its 5_000 to the lot,
      # where it absorbs the 5_000 clawback instead of becoming available.
      apply_ops!([
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-21"
        })
      ])

      assert %{
               "data" => %{
                 "credit_shortfall_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = get_ledger()

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit("guest-22")
    end

    test "excess over the clawback becomes available again on refundable settlement" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 2_000}),
        charge_back_payment_op()
      ])

      # clawback is 9_000 (11_000 entitlement - 2_000 removed... wait: the
      # lot had 11_000, group-82 took 2_000 leaving 9_000 remaining; the
      # entitlement of 11_000 removes 9_000 and claws back 2_000).
      assert %{"data" => %{"credit_shortfall_cents" => 2_000}} = get_ledger()

      apply_ops!([
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-21"
        })
      ])

      # The 2_000 return is absorbed fully by the 2_000 clawback.
      assert %{
               "data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}
             } = get_ledger()
    end

    test "entitlements of several payments in one lot telescope exactly" do
      # Two payments settle into one lot: 6_000 and 4_000. Entitlements are
      # 6_600 (through pay-1) and 11_000 - 6_600 = 4_400 (through pay-2).
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 6_000}),
        record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 4_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      assert %{"data" => %{"available_cents" => 11_000}} = get_credit("guest-22")

      apply_ops!([
        charge_back_payment_op(%{
          "operation_id" => "op-cb-1",
          "payment_operation_id" => "op-pay"
        })
      ])

      # Removing pay-1's 6_600 entitlement leaves pay-2's 4_400.
      assert %{"data" => %{"available_cents" => 4_400}} = get_credit("guest-22")

      apply_ops!([
        charge_back_payment_op(%{
          "operation_id" => "op-cb-2",
          "payment_operation_id" => "op-pay-2"
        })
      ])

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit("guest-22")
    end

    test "chargebacks reverse every remaining disposition of the payment" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})
      ])

      # room-b's 1_000 was refunded; room-a's 9_000 is still held.
      conn = post_batch([charge_back_payment_op()])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "charged_back_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 10_000
               }
             } = get_ledger()

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "recorded_cents" => 10_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "charged_back_cents" => 10_000
               }
             } = json_response(conn, 200)
    end

    test "chargebacks are durably idempotent" do
      ops = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        charge_back_payment_op()
      ]

      conn = post_batch(ops)
      assert %{"results" => results} = json_response(conn, 200)

      conn = post_batch(ops)
      assert %{"results" => ^results} = json_response(conn, 200)

      assert %{"data" => %{"cash_charged_back_cents" => 10_000}} = get_ledger()
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports each disposition of one payment's cash" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 9_500})
      ])

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10_000,
                 "held_cents" => 10_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "dispositions sum to the recorded amount as the payment moves" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        reduce_cash_payment_op(%{"amount_cents" => 4_000}),
        cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-20"})
      ])

      # reduce took room-b's 1_000 and 3_000 of room-a; room-b's remaining
      # settled cash refunds on the partial cancellation.
      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "recorded_cents" => 10_000,
                 "held_cents" => 6_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 4_000,
                 "charged_back_cents" => 0
               }
             } = json_response(conn, 200)

      dispositions =
        for key <- ~w(held_cents refunded_cents retained_cents converted_to_credit_cents
                      reduced_cents charged_back_cents) do
          json_response(conn, 200)["data"][key]
        end

      assert Enum.sum(dispositions) == 10_000
    end

    test "reading a statement never changes state" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn = get_payment("op-pay")
      assert %{"data" => %{"held_cents" => 10_000}} = json_response(conn, 200)

      conn = get_payment("op-pay")
      assert %{"data" => %{"held_cents" => 10_000}} = json_response(conn, 200)

      assert %{"data" => %{"revision" => 2}} = get_group("group-81")
    end

    test "404 for an unknown identifier, 422 for non-payment or rejected records" do
      conn = get_payment("op-missing")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)

      apply_ops([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_501})
      ])

      conn = get_payment("op-open")
      assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)

      conn = get_payment("op-pay")
      assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)
    end
  end

  describe "legacy senior block" do
    test "the unattributed senior block is allocated first and can never be targeted" do
      # Build a legacy-funded group directly: no operation records exist for
      # its funding, so it forms one senior block of cash.
      group =
        GroupStay.Groups.Group.create_changeset(%{
          group_id: "group-legacy",
          guest_id: "guest-22",
          property_id: "ams-canal",
          rate_plan: "flexible",
          status: "active",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          revision: 1,
          policy_version: "flex-14",
          refundable_until: ~D[2026-11-26],
          lodging_total_cents: 97_500,
          deposit_due_cents: 19_500,
          deposit_paid_cents: 10_000,
          cash_paid_cents: 10_000,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0,
          rooms: [
            %{
              position: 0,
              room_id: "room-a",
              nightly_rate_cents: 15_000,
              status: "active",
              deposit_due_cents: 9_000
            },
            %{
              position: 1,
              room_id: "room-b",
              nightly_rate_cents: 17_500,
              status: "active",
              deposit_due_cents: 10_500
            }
          ]
        })
        |> Repo.insert!()

      [room_a, room_b] = group.rooms

      for {room, amount} <- [{room_a, 9_000}, {room_b, 1_000}] do
        %GroupStay.Groups.RoomAllocation{}
        |> GroupStay.Groups.RoomAllocation.changeset(%{
          room_id: room.id,
          kind: "cash",
          amount_cents: amount,
          disposition: "held",
          position: room.position
        })
        |> Repo.insert!()

        room
        |> GroupStay.Groups.Room.changeset(%{cash_paid_cents: room.cash_paid_cents + amount})
        |> Repo.update!()
      end

      # The senior block sits alongside recorded funding in allocation order.
      apply_ops!([
        record_cash_payment_op(%{
          "group_id" => "group-legacy",
          "amount_cents" => 9_500
        }),
        cancel_group_op(%{
          "group_id" => "group-legacy",
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      ])

      # Senior block 10_000 first, then op-pay's 9_500 -> bonus 19_500 * 1.1.
      assert %{"data" => %{"available_cents" => 21_450}} = get_credit("guest-22")

      # Charging back the recorded payment removes only its own entitlement:
      # bonus through senior block is 11_000, through op-pay is 21_450, so
      # op-pay's entitlement is 10_450 and the senior 11_000 remains.
      apply_ops!([
        charge_back_payment_op(%{"payment_operation_id" => "op-pay"})
      ])

      assert %{"data" => %{"available_cents" => 11_000}} = get_credit("guest-22")

      # With the recorded payment charged back, nothing held remains to
      # reduce; the senior block itself has no durable identity to target.
      conn =
        post_batch([
          reduce_cash_payment_op(%{"payment_operation_id" => "op-pay", "amount_cents" => 1})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_not_reducible"}]} =
               json_response(conn, 200)
    end
  end
end
