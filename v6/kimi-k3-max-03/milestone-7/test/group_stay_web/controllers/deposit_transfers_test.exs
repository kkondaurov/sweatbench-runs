defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

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

  defp open_destination(overrides \\ %{}) do
    open_group_op(
      Map.merge(%{"operation_id" => "op-open-2", "group_id" => "group-82"}, overrides)
    )
  end

  # The default groups have two rooms over three nights: room-a deposit 9_000
  # and room-b deposit 10_500 (19_500 due). A 10_000 payment fills room-a
  # (9_000) then room-b (1_000).
  describe "transfer_deposit" do
    test "moves held cash in reverse allocation order and reports both groups" do
      apply_ops!([open_group_op(), record_cash_payment_op(%{"amount_cents" => 10_000})])
      apply_ops!([open_destination()])

      conn = post_batch([transfer_deposit_op(%{"amount_cents" => 1_000})])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-transfer",
                   "status" => "applied",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-82",
                   "amount_cents" => 1_000,
                   "source_outstanding_deposit_cents" => 10_500,
                   "destination_outstanding_deposit_cents" => 18_500,
                   "source_revision" => 3,
                   "destination_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      # The most recently created allocation (room-b's 1_000) moves first.
      assert %{
               "data" => %{
                 "outstanding_deposit_cents" => 10_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = get_group("group-81")

      assert %{
               "data" => %{
                 "outstanding_deposit_cents" => 18_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 1_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = get_group("group-82")
    end

    test "changes no ledger total" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination()
      ])

      assert %{"data" => before} = get_ledger()

      apply_ops!([transfer_deposit_op(%{"amount_cents" => 4_000})])

      assert %{"data" => ^before} = get_ledger()
    end

    test "observes earlier operations in the same batch and honors both revision guards" do
      results =
        apply_ops!([
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 10_000}),
          open_destination(),
          transfer_deposit_op(%{
            "amount_cents" => 1_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          }),
          transfer_deposit_op(%{
            "operation_id" => "op-transfer-2",
            "amount_cents" => 500,
            "expected_revision" => 3,
            "destination_expected_revision" => 2
          })
        ])

      assert [
               _open,
               _pay,
               _open_2,
               %{"source_revision" => 3, "destination_revision" => 2},
               %{"source_revision" => 4, "destination_revision" => 3}
             ] = results
    end

    test "rejects when the source group is missing, before looking at the destination" do
      conn =
        post_batch([
          transfer_deposit_op(%{
            "source_group_id" => "group-missing",
            "destination_group_id" => "group-also-missing"
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "group-missing",
                   "operation_id" => "op-transfer"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects when the destination group is missing" do
      apply_ops!([open_group_op()])

      conn = post_batch([transfer_deposit_op(%{"destination_group_id" => "group-missing"})])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "group-missing"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "destination existence resolves before the source revision guard" do
      apply_ops!([open_group_op()])

      conn =
        post_batch([
          transfer_deposit_op(%{
            "destination_group_id" => "group-missing",
            "expected_revision" => 99
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "group-missing"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "checks the source revision before the destination revision" do
      apply_ops!([open_group_op(), open_destination()])

      conn =
        post_batch([
          transfer_deposit_op(%{
            "expected_revision" => 9,
            "destination_expected_revision" => 9
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 9,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "a destination revision mismatch reports the destination's revision details" do
      apply_ops!([open_group_op(), open_destination()])

      conn = post_batch([transfer_deposit_op(%{"destination_expected_revision" => 7})])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-82",
                   "expected_revision" => 7,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects a transfer between the same group or different guests" do
      apply_ops!([open_group_op(), record_cash_payment_op(%{"amount_cents" => 1_000})])

      conn =
        post_batch([transfer_deposit_op(%{"destination_group_id" => "group-81"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_transfer"}]} =
               json_response(conn, 200)

      apply_ops!([open_destination(%{"guest_id" => "guest-99"})])

      conn =
        post_batch([transfer_deposit_op(%{"operation_id" => "op-transfer-2"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_transfer"}]} =
               json_response(conn, 200)
    end

    test "rejects when either group is not active, naming that group" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 1_000}),
        open_destination()
      ])

      apply_ops!([cancel_group_op(%{"group_id" => "group-82", "occurred_on" => "2026-11-20"})])

      conn = post_batch([transfer_deposit_op()])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-82"}
               ]
             } = json_response(conn, 200)

      apply_ops!([
        cancel_group_op(%{"operation_id" => "op-cancel-2", "occurred_on" => "2026-11-20"}),
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"})
      ])

      conn =
        post_batch([
          transfer_deposit_op(%{
            "operation_id" => "op-transfer-2",
            "destination_group_id" => "group-83"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects unusable amounts" do
      apply_ops!([open_group_op(), open_destination()])

      for {amount, index} <- Enum.with_index([0, -100, "100", 1.5]) do
        conn =
          post_batch([
            transfer_deposit_op(%{
              "operation_id" => "op-transfer-#{index}",
              "amount_cents" => amount
            })
          ])

        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_amount"}]} =
                 json_response(conn, 200)
      end
    end

    test "rejects when the source holds less funding than requested" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination()
      ])

      conn = post_batch([transfer_deposit_op(%{"amount_cents" => 10_001})])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects when the destination's outstanding deposit is smaller than requested" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 19_000
        })
      ])

      # group-82's outstanding is 500; the source holds plenty.
      conn = post_batch([transfer_deposit_op(%{"amount_cents" => 501})])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects operations missing their group identifiers" do
      apply_ops!([open_group_op(), open_destination()])

      conn =
        post_batch([
          %{
            "operation_id" => "op-transfer-no-source",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-07",
            "destination_group_id" => "group-82",
            "amount_cents" => 100
          }
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)

      conn =
        post_batch([
          %{
            "operation_id" => "op-transfer-no-destination",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-07",
            "source_group_id" => "group-81",
            "amount_cents" => 100
          }
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end

    test "a rejected transfer leaves both groups and the ledger unchanged" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination()
      ])

      apply_ops([transfer_deposit_op(%{"amount_cents" => 10_001})])

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 10_000}} = get_group("group-81")
      assert %{"data" => %{"revision" => 1, "cash_paid_cents" => 0}} = get_group("group-82")
      assert %{"data" => %{"cash_held_cents" => 10_000}} = get_ledger()
    end

    test "transfers are durably idempotent" do
      ops = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ]

      conn = post_batch(ops)
      assert %{"results" => results} = json_response(conn, 200)

      conn = post_batch(ops)
      assert %{"results" => ^results} = json_response(conn, 200)

      # The funding moved exactly once.
      assert %{"data" => %{"cash_paid_cents" => 1_000, "revision" => 2}} = get_group("group-82")
      assert %{"data" => %{"cash_held_cents" => 10_000}} = get_ledger()

      conn = get(build_conn(), ~p"/api/v1/operations/op-transfer")

      assert %{
               "data" => %{
                 "status" => "applied",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-82",
                 "amount_cents" => 1_000
               }
             } = json_response(conn, 200)
    end

    test "a rejected transfer is remembered and replayed even when it would now succeed" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 1_000}),
        open_destination()
      ])

      conn = post_batch([transfer_deposit_op(%{"amount_cents" => 2_000})])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} = rejected
               ]
             } = json_response(conn, 200)

      apply_ops!([
        record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 9_000})
      ])

      conn = post_batch([transfer_deposit_op(%{"amount_cents" => 2_000})])
      assert %{"results" => [^rejected]} = json_response(conn, 200)

      assert %{"data" => %{"cash_paid_cents" => 0}} = get_group("group-82")
    end
  end

  describe "transfer_deposit movement" do
    test "draws the most recently created allocation first, regardless of funding kind" do
      # group-82 holds credit on room-a (applied first) and cash on room-b
      # (applied later); the transfer takes the later cash allocation first.
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_destination(),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 9_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 10_000
        }),
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"}),
        transfer_deposit_op(%{
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 2_000
        })
      ])

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 2_000, "credit_paid_cents" => 0},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = get_group("group-83")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 0, "credit_paid_cents" => 9_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 8_000, "credit_paid_cents" => 0}
                 ]
               }
             } = get_group("group-82")
    end

    test "fills destination rooms in original order, preserving the order units were drawn" do
      # group-82 holds, oldest to newest: room-a cash 5_000 (pay-2), room-a
      # credit 4_000, room-b cash 3_000 (pay-3). The 12_000 transfer draws
      # them newest-first and fills room-a of group-83 in that draw order.
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 5_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_destination(),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 5_000
        }),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 4_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-3",
          "group_id" => "group-82",
          "amount_cents" => 3_000
        })
      ])

      results =
        apply_ops!([
          open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"}),
          transfer_deposit_op(%{
            "source_group_id" => "group-82",
            "destination_group_id" => "group-83",
            "amount_cents" => 12_000
          })
        ])

      assert [
               _open,
               %{
                 "source_revision" => 5,
                 "destination_revision" => 2,
                 "source_outstanding_deposit_cents" => 19_500,
                 "destination_outstanding_deposit_cents" => 7_500
               }
             ] = results

      # room-a of group-83 (due 9_000) fills with the drawn units in order:
      # 3_000 cash, then 4_000 credit, then 2_000 of the oldest cash; its last
      # 3_000 spills into room-b.
      assert %{
               "data" => %{
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 5_000,
                     "credit_paid_cents" => 4_000
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 3_000, "credit_paid_cents" => 0}
                 ]
               }
             } = get_group("group-83")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 0, "credit_paid_cents" => 0},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = get_group("group-82")
    end

    test "moved credit keeps its original lot and changes no liability" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_destination(),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 5_000})
      ])

      assert %{"data" => %{"credit_liability_cents" => 11_000}} = get_ledger()

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"}),
        transfer_deposit_op(%{
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 2_000
        })
      ])

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "credit_paid_cents" => 2_000},
                   %{"room_id" => "room-b", "credit_paid_cents" => 0}
                 ]
               }
             } = get_group("group-83")

      assert %{"data" => %{"rooms" => [%{"credit_paid_cents" => 3_000} | _]}} =
               get_group("group-82")

      # Applying credit paused expiry; the transfer does not resume it and
      # the liability (6_000 available + 5_000 applied) is unchanged.
      assert %{"data" => %{"available_cents" => 6_000}} = get_credit("guest-22")
      assert %{"data" => %{"credit_liability_cents" => 11_000}} = get_ledger()
    end
  end

  describe "settlement after transfers" do
    test "transferred cash settles under the destination group's cancellation policy" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn =
        post_batch([
          cancel_group_op(%{"group_id" => "group-82", "occurred_on" => "2026-11-20"})
        ])

      assert %{"results" => [%{"status" => "applied", "refunded_cents" => 1_000}]} =
               json_response(conn, 200)

      assert %{"data" => %{"cash_held_cents" => 9_000, "cash_refunded_cents" => 1_000}} =
               get_ledger()
    end

    test "transferred cash is retained on a non-refundable destination cancellation" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn =
        post_batch([
          cancel_group_op(%{"group_id" => "group-82", "occurred_on" => "2026-12-01"})
        ])

      assert %{"results" => [%{"status" => "applied", "retained_cents" => 1_000}]} =
               json_response(conn, 200)

      assert %{"data" => %{"cash_held_cents" => 9_000, "cash_retained_cents" => 1_000}} =
               get_ledger()
    end

    test "the credit bonus applies to transferred cash settled at the destination" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn =
        post_batch([
          cancel_group_op(%{
            "group_id" => "group-82",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 1_100}
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"available_cents" => 1_100}} = get_credit("guest-22")
    end

    test "transferred credit restores to its original lot without another bonus" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_destination(),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 5_000}),
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"}),
        transfer_deposit_op(%{
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 2_000
        })
      ])

      conn =
        post_batch([
          cancel_group_op(%{
            "operation_id" => "op-cancel-2",
            "group_id" => "group-83",
            "occurred_on" => "2026-11-21"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      # The 2_000 returns to the original lot with its original expiry.
      assert %{
               "data" => %{
                 "available_cents" => 8_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel",
                     "remaining_cents" => 8_000,
                     "expires_on" => "2027-11-20"
                   }
                 ]
               }
             } = get_credit("guest-22")
    end
  end

  describe "reductions and chargebacks after transfers" do
    test "a reduction follows the payment's allocations across groups, most recent first" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn = post_batch([reduce_cash_payment_op(%{"amount_cents" => 500})])

      # The result reports the addressed original payment group only.
      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 10_500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      # The moved allocation (most recently created) is reduced first, so
      # group-82's room reopens — and its revision increments even though the
      # operation was not addressed to it.
      assert %{"data" => %{"revision" => 4}} = get_group("group-81")

      assert %{
               "data" => %{"revision" => 3, "outstanding_deposit_cents" => 19_000}
             } = get_group("group-82")

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 9_500,
                 "reduced_cents" => 500,
                 "held_by_group" => [
                   %{"group_id" => "group-81", "amount_cents" => 9_000},
                   %{"group_id" => "group-82", "amount_cents" => 500}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "the reduction guard still checks only the original payment group" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn =
        post_batch([
          reduce_cash_payment_op(%{"amount_cents" => 100, "expected_revision" => 2})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 2,
                   "actual_revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch([
          reduce_cash_payment_op(%{
            "operation_id" => "op-reduce-2",
            "amount_cents" => 100,
            "expected_revision" => 3
          })
        ])

      assert %{"results" => [%{"status" => "applied", "revision" => 4}]} =
               json_response(conn, 200)
    end

    test "a chargeback removes held allocations across groups and bumps every changed group" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn = post_batch([charge_back_payment_op()])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "charged_back_cents" => 10_000,
                   "outstanding_deposit_cents" => 19_500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"revision" => 4}} = get_group("group-81")

      assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 19_500}} =
               get_group("group-82")

      assert %{
               "data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000}
             } = get_ledger()
    end

    test "funding moved through a chain of transfers keeps its payment identity" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"}),
        transfer_deposit_op(%{"amount_cents" => 1_000}),
        transfer_deposit_op(%{
          "operation_id" => "op-transfer-2",
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 500
        })
      ])

      # The cash still belongs to op-pay and now funds group-83.
      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 10_000,
                 "held_by_group" => [
                   %{"group_id" => "group-81", "amount_cents" => 9_000},
                   %{"group_id" => "group-82", "amount_cents" => 500},
                   %{"group_id" => "group-83", "amount_cents" => 500}
                 ]
               }
             } = json_response(conn, 200)

      # A reduction still follows it to group-83: the slice that moved there
      # is the payment's most recent allocation, so it is reduced first.
      apply_ops!([reduce_cash_payment_op(%{"amount_cents" => 500})])

      assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 19_500}} =
               get_group("group-83")

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 9_500,
                 "held_by_group" => [
                   %{"group_id" => "group-81", "amount_cents" => 9_000},
                   %{"group_id" => "group-82", "amount_cents" => 500}
                 ]
               }
             } = json_response(conn, 200)
    end
  end

  describe "payment statement evolution" do
    test "a payment that never transferred keeps the earlier statement shape" do
      apply_ops!([open_group_op(), record_cash_payment_op(%{"amount_cents" => 10_000})])

      conn = get_payment("op-pay")

      assert %{"data" => statement} = json_response(conn, 200)
      refute Map.has_key?(statement, "held_by_group")

      assert %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 10_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             } = statement
    end

    test "after a transfer the statement adds held_by_group ordered by group_id" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000})
      ])

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 10_000,
                 "held_by_group" => held_by_group
               }
             } = json_response(conn, 200)

      assert held_by_group == [
               %{"group_id" => "group-81", "amount_cents" => 9_000},
               %{"group_id" => "group-82", "amount_cents" => 1_000}
             ]
    end

    test "groups whose held cash settled away are omitted; an empty list remains" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_destination(),
        transfer_deposit_op(%{"amount_cents" => 1_000}),
        cancel_group_op(%{"group_id" => "group-82", "occurred_on" => "2026-11-20"})
      ])

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 9_000,
                 "refunded_cents" => 1_000,
                 "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 9_000}]
               }
             } = json_response(conn, 200)

      # Reduce the remaining held cash away: the payment participated in a
      # transfer, so the field stays, now empty.
      apply_ops!([reduce_cash_payment_op(%{"amount_cents" => 9_000})])

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)
    end
  end
end
