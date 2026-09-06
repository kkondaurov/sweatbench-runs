defmodule GroupStayWeb.Controllers.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Groups.Group
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  @occurred_on "2026-10-03"

  describe "transfer_deposit" do
    test "moves held funding from the source's most recent allocations to the destination's rooms in order",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 5_000})
        ])

      assert %{"results" => [_, _, _, transfer]} = json_response(conn, 200)

      # The payment filled room-a (9_000) then room-b (1_000). The transfer
      # draws room-b's 1_000 first and then 4_000 of room-a's, and fills the
      # destination's room-c with all of it.
      assert transfer == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 14_500,
               "destination_outstanding_deposit_cents" => 6_000,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 5_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ],
               "cash_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500
             } = fetch_group!(conn, "group-81")

      assert %{
               "rooms" => [
                 %{"room_id" => "room-c", "cash_paid_cents" => 5_000, "credit_paid_cents" => 0},
                 %{"room_id" => "room-d", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ],
               "deposit_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 6_000
             } = fetch_group!(conn, "group-92")

      # A transfer only changes which rooms hold the funding.
      assert %{
               "cash_held_cents" => 10_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0
             } = ledger(conn)
    end

    test "draws most recent allocations first regardless of funding kind and keeps provenance", %{
      conn: conn
    } do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(),
              open_destination_operation(),
              record_payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 4_000}),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-81",
                "amount_cents" => 5_000
              }),
              record_payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 5_000})
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # Held funding: room-a holds 4_000 of cash and 5_000 of credit, room-b
      # holds 5_000 of cash. The 10_000 transfer draws the most recent
      # allocation first - op-pay-2's cash, then the credit - and fills the
      # destination's rooms in their original order with the units in the
      # order they were drawn.
      conn =
        post_operations(conn, [transfer_operation(%{"amount_cents" => 10_000})])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 4_000, "credit_paid_cents" => 0},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ],
               "outstanding_deposit_cents" => 15_500
             } = fetch_group!(conn, "group-81")

      assert %{
               "rooms" => [
                 %{
                   "room_id" => "room-c",
                   "cash_paid_cents" => 5_000,
                   "credit_paid_cents" => 1_000
                 },
                 %{
                   "room_id" => "room-d",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 4_000
                 }
               ],
               "deposit_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 1_000
             } = fetch_group!(conn, "group-92")

      # Cash keeps its payment identity: op-pay-2 now holds only on the
      # destination, op-pay-1 only on the source.
      assert %{"data" => second} = json_response(get(conn, "/api/v1/payments/op-pay-2"), 200)

      assert %{
               "held_cents" => 5_000,
               "held_by_group" => [%{"group_id" => "group-92", "amount_cents" => 5_000}]
             } = second

      # op-pay-1's cash never participated in a transfer, so its statement
      # keeps the earlier shape.
      assert %{"data" => first} = json_response(get(conn, "/api/v1/payments/op-pay-1"), 200)

      assert %{"held_cents" => 4_000} = first
      refute Map.has_key?(first, "held_by_group")

      # The transferred credit is still applied, so the liability is unchanged.
      assert %{"credit_liability_cents" => 11_000} = ledger(conn, on: "2027-11-20")
    end

    test "adds held_by_group to the payment statement once its funding participated in a transfer",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000})
        ])

      assert %{"data" => before} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)
      refute Map.has_key?(before, "held_by_group")

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t1", "amount_cents" => 4_000})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{
               "held_cents" => 10_000,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 6_000},
                 %{"group_id" => "group-92", "amount_cents" => 4_000}
               ]
             } = statement

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t2", "amount_cents" => 6_000})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      # Groups with no held cash are omitted and the amounts still sum to
      # held_cents.
      assert %{
               "held_cents" => 10_000,
               "held_by_group" => [%{"group_id" => "group-92", "amount_cents" => 10_000}]
             } = statement
    end

    test "returns an empty held_by_group list after none of the payment's cash remains held", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 10_000}),
          charge_back_operation(%{"operation_id" => "op-cb"})
        ])

      assert %{"results" => [_, _, _, _, chargeback]} = json_response(conn, 200)

      assert %{
               "status" => "applied",
               "charged_back_cents" => 10_000,
               "revision" => 4
             } = chargeback

      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{
               "held_cents" => 0,
               "charged_back_cents" => 10_000,
               "held_by_group" => []
             } = statement

      # The chargeback changed the revision of both the addressed group and
      # the group whose rooms lost the funding.
      assert %{
               "revision" => 4,
               "rooms" => [%{"cash_paid_cents" => 0}, %{"cash_paid_cents" => 0}]
             } = fetch_group!(conn, "group-81")

      assert %{
               "revision" => 3,
               "rooms" => [%{"cash_paid_cents" => 0}, %{"cash_paid_cents" => 0}]
             } = fetch_group!(conn, "group-92")

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000} = ledger(conn)
    end

    test "transferred credit remains applied with expiry paused and restores to its original lot",
         %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(),
              open_destination_operation(),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-81",
                "amount_cents" => 5_000
              }),
              transfer_operation(%{"amount_cents" => 5_000})
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "rooms" => [
                 %{"room_id" => "room-c", "credit_paid_cents" => 5_000},
                 %{"room_id" => "room-d", "credit_paid_cents" => 0}
               ]
             } = fetch_group!(conn, "group-92")

      conn =
        post_operations(conn, [
          cancel_operation(%{
            "operation_id" => "op-cancel-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-26"
          })
        ])

      # The destination had no cash to refund; the credit simply returns.
      assert %{
               "results" => [
                 %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}
               ]
             } =
               json_response(conn, 200)

      # The credit is back on its original lot with its original expiry and
      # never received a second bonus.
      assert %{"data" => credit} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-source",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-21"
                 }
               ]
             }

      assert %{"credit_liability_cents" => 11_000} = ledger(conn, on: "2027-11-20")
    end

    test "transferred credit is consumed when the destination settles non-refundably", %{
      conn: conn
    } do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(),
              open_destination_operation(),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-81",
                "amount_cents" => 5_000
              }),
              transfer_operation(%{"amount_cents" => 5_000}),
              cancel_operation(%{
                "operation_id" => "op-cancel-92",
                "group_id" => "group-92",
                "occurred_on" => "2026-11-27"
              })
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The lot's unapplied 6_000 remains; the consumed 5_000 left the
      # liability.
      assert %{"data" => %{"available_cents" => 6_000}} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)

      assert %{"credit_liability_cents" => 6_000} = ledger(conn, on: "2027-11-20")
    end

    test "transferred cash settles under the destination's policy and earns the bonus there", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 10_000}),
          cancel_operation(%{
            "operation_id" => "op-cancel-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, _, _, cancellation]} = json_response(conn, 200)

      assert %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 11_000} =
               cancellation

      assert %{
               "cash_converted_to_credit_cents" => 10_000,
               "cash_held_cents" => 0,
               "credit_liability_cents" => 11_000
             } = ledger(conn, on: "2027-11-20")
    end

    test "a chargeback revokes the entitlement of cash that was transferred and converted", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 10_000}),
          cancel_operation(%{
            "operation_id" => "op-cancel-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          }),
          charge_back_operation(%{"operation_id" => "op-cb"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The converted principal moved to charged-back cash and the lot's
      # whole entitlement was revoked.
      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = ledger(conn, on: "2027-11-20")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)

      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{
               "held_cents" => 0,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 10_000,
               "held_by_group" => []
             } = statement
    end

    test "reductions carve a payment's held cash wherever it currently funds rooms", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"operation_id" => "op-transfer", "amount_cents" => 1_000}),
          reduce_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1_000
          })
        ])

      assert %{"results" => [_, _, _, _, reduction]} = json_response(conn, 200)

      # The transferred 1_000 is the payment's most recent allocation, so the
      # reduction carves it from the destination. The source's outstanding is
      # unaffected, and its revision is the one reported.
      assert reduction == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 10_500,
               "revision" => 4
             }

      assert %{
               "revision" => 4,
               "rooms" => [%{"cash_paid_cents" => 9_000}, %{"cash_paid_cents" => 0}]
             } =
               fetch_group!(conn, "group-81")

      assert %{"revision" => 3, "outstanding_deposit_cents" => 11_000} =
               fetch_group!(conn, "group-92")

      assert %{"cash_held_cents" => 9_000, "cash_reduced_cents" => 1_000} = ledger(conn)

      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{
               "held_cents" => 9_000,
               "reduced_cents" => 1_000,
               "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 9_000}]
             } = statement
    end

    test "a reduction may carve a spanning payment's cash across both groups", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 9_500}),
          reduce_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 6_000
          })
        ])

      assert %{"results" => [_, _, _, _, reduction]} = json_response(conn, 200)

      # The transfer left 500 of the payment on room-a and spread 9_500 over
      # the destination's rooms. The 6_000 reduction walks the payment's
      # allocations newest first and stops inside the destination.
      assert reduction == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 6_000,
               "outstanding_deposit_cents" => 19_000,
               "revision" => 4
             }

      assert %{
               "revision" => 4,
               "rooms" => [%{"cash_paid_cents" => 500}, %{"cash_paid_cents" => 0}]
             } =
               fetch_group!(conn, "group-81")

      assert %{
               "revision" => 3,
               "rooms" => [
                 %{"room_id" => "room-c", "cash_paid_cents" => 3_500},
                 %{"room_id" => "room-d", "cash_paid_cents" => 0}
               ],
               "outstanding_deposit_cents" => 7_500
             } = fetch_group!(conn, "group-92")

      assert %{"cash_held_cents" => 4_000, "cash_reduced_cents" => 6_000} = ledger(conn)

      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{
               "held_cents" => 4_000,
               "reduced_cents" => 6_000,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 500},
                 %{"group_id" => "group-92", "amount_cents" => 3_500}
               ]
             } = statement
    end

    test "a spanning payment settles, reduces, and charges back with consistent dispositions", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 9_500}),
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-c",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-27",
            "room_ids" => ["room-c"]
          }),
          reduce_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 3_500
          }),
          charge_back_operation(%{"operation_id" => "op-cb"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # recorded 10_000 = reduced 3_500 + charged_back 6_500 (the retained
      # 6_000 was reclassified by the chargeback, and the held 500 was
      # carved from room-a).
      assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

      assert %{
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3_500,
               "charged_back_cents" => 6_500,
               "held_by_group" => []
             } = statement

      assert %{
               "cash_held_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_reduced_cents" => 3_500,
               "cash_charged_back_cents" => 6_500
             } = ledger(conn)

      assert %{"rooms" => [%{"cash_paid_cents" => 0}, %{"cash_paid_cents" => 0}]} =
               fetch_group!(conn, "group-81")

      assert %{
               "rooms" => [
                 %{"room_id" => "room-c", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-d", "cash_paid_cents" => 0}
               ],
               "outstanding_deposit_cents" => 5_000
             } = fetch_group!(conn, "group-92")
    end

    test "accepts expected_revision for both groups and guards each before the transfer rules", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000}),
          transfer_operation(%{
            "operation_id" => "op-transfer",
            "amount_cents" => 2_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])

      assert %{"results" => [_, _, _, %{"status" => "applied", "source_revision" => 3}]} =
               json_response(conn, 200)
    end

    test "resolves source existence, then destination existence", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), open_destination_operation()])

      conn =
        post_operations(conn, [
          transfer_operation(%{
            "operation_id" => "op-t1",
            "source_group_id" => "no-such",
            "destination_group_id" => "also-missing"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "group_not_found", "group_id" => "no-such"}
               ]
             } =
               json_response(conn, 200)

      conn =
        post_operations(conn, [
          transfer_operation(%{
            "operation_id" => "op-t2",
            "destination_group_id" => "also-missing"
          })
        ])

      assert %{"results" => [%{"code" => "group_not_found", "group_id" => "also-missing"}]} =
               json_response(conn, 200)
    end

    test "checks the source revision, then the destination revision, before the transfer rules",
         %{
           conn: conn
         } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          transfer_operation(%{"expected_revision" => 7})
        ])

      assert %{"results" => [_, _, stale]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 7,
               "actual_revision" => 1
             }

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t2", "destination_expected_revision" => 7})
        ])

      assert %{"results" => [stale]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "op-t2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 7,
               "actual_revision" => 1
             }

      # A destination revision mismatch is checked before the rules reject the
      # same-group shape.
      conn =
        post_operations(conn, [
          transfer_operation(%{
            "operation_id" => "op-t3",
            "destination_group_id" => "group-81",
            "destination_expected_revision" => 7
          })
        ])

      assert %{"results" => [%{"code" => "stale_revision", "group_id" => "group-81"}]} =
               json_response(conn, 200)
    end

    test "rejects transfers between the same group or different guests", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_group_operation(%{
            "operation_id" => "op-open-other",
            "group_id" => "group-other",
            "guest_id" => "guest-31",
            "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}]
          })
        ])

      conn =
        post_operations(conn, [
          transfer_operation(%{
            "operation_id" => "op-t1",
            "destination_group_id" => "group-other"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_transfer"}]} =
               json_response(conn, 200)

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t2", "destination_group_id" => "group-81"})
        ])

      assert %{"results" => [%{"code" => "invalid_transfer"}]} = json_response(conn, 200)

      # No rejection advanced a revision.
      assert %{"revision" => 1} = fetch_group!(conn, "group-81")
      assert %{"revision" => 1} = fetch_group!(conn, "group-other")
    end

    test "rejects inactive groups, naming the group, before the amount rules", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          cancel_operation(%{"operation_id" => "op-cancel", "occurred_on" => "2026-11-27"})
        ])

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t1", "amount_cents" => 0})
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"}
               ]
             } =
               json_response(conn, 200)

      conn =
        post_operations(conn, [
          transfer_operation(%{
            "operation_id" => "op-t2",
            "source_group_id" => "group-92",
            "destination_group_id" => "group-81"
          })
        ])

      assert %{"results" => [%{"code" => "group_not_active", "group_id" => "group-81"}]} =
               json_response(conn, 200)
    end

    test "rejects non-positive amounts with invalid_amount", %{conn: conn} do
      conn =
        post_operations(conn, [open_group_operation(), open_destination_operation()])

      for {amount, index} <- Enum.with_index([nil, 0, -1_000, "1000", 1_000.0]) do
        conn =
          post_operations(conn, [
            transfer_operation(%{
              "operation_id" => "op-amount-#{index}",
              "amount_cents" => amount
            })
          ])

        assert_rejected(conn, "invalid_amount")
      end
    end

    test "rejects amounts beyond the held funding or the destination's outstanding", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4_000})
        ])

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t1", "amount_cents" => 4_001})
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}]
             } =
               json_response(conn, 200)

      # Held funding is checked before the destination's outstanding.
      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 11_000}),
          transfer_operation(%{"operation_id" => "op-t2", "amount_cents" => 11_001})
        ])

      assert %{"results" => [_, %{"code" => "transfer_exceeds_outstanding"}]} =
               json_response(conn, 200)

      # The rejections changed nothing.
      assert %{"revision" => 3, "cash_paid_cents" => 15_000} = fetch_group!(conn, "group-81")
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = fetch_group!(conn, "group-92")
      assert %{"cash_held_cents" => 15_000} = ledger(conn)
    end

    test "moves legacy funding as part of held funding", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), open_destination_operation()])
      group = Repo.get_by!(Group, group_id: "group-81")

      Repo.insert!(%Entry{
        group_id: group.id,
        type: "cash_held",
        amount_cents: 4_000,
        occurred_on: ~D[2026-01-05],
        operation_id: "legacy-pay"
      })

      conn = post_operations(conn, [transfer_operation(%{"amount_cents" => 4_000})])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"rooms" => [%{"cash_paid_cents" => 0}, %{"cash_paid_cents" => 0}]} =
               fetch_group!(conn, "group-81")

      assert %{
               "rooms" => [
                 %{"room_id" => "room-c", "cash_paid_cents" => 4_000},
                 %{"room_id" => "room-d", "cash_paid_cents" => 0}
               ]
             } = fetch_group!(conn, "group-92")

      assert %{"cash_held_cents" => 4_000} = ledger(conn)

      # Legacy funding has no durable payment identity to reduce.
      conn =
        post_operations(conn, [
          reduce_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "legacy-pay",
            "amount_cents" => 1_000
          })
        ])

      assert %{"results" => [%{"code" => "operation_not_found"}]} = json_response(conn, 200)
    end

    test "retries return the exact stored result without moving funding again", %{conn: conn} do
      transfer = transfer_operation(%{"operation_id" => "op-t", "amount_cents" => 5_000})

      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer
        ])

      assert %{"results" => [_, _, _, first]} = json_response(conn, 200)

      conn = post_operations(conn, [transfer])
      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == first

      assert %{"revision" => 3, "cash_paid_cents" => 5_000} = fetch_group!(conn, "group-81")
      assert %{"revision" => 2, "deposit_paid_cents" => 5_000} = fetch_group!(conn, "group-92")

      conn =
        post_operations(conn, [
          transfer_operation(%{"operation_id" => "op-t", "amount_cents" => 6_000})
        ])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)
    end

    test "sees changes made by earlier operations in the same batch", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
          transfer_operation(%{"amount_cents" => 5_000})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "rooms" => [
                 %{"room_id" => "room-c", "cash_paid_cents" => 5_000},
                 %{"room_id" => "room-d", "cash_paid_cents" => 0}
               ]
             } = fetch_group!(conn, "group-92")
    end
  end

  defp open_destination_operation(overrides \\ %{}) do
    open_group_operation(
      Map.merge(
        %{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "rooms" => [
            %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-d", "nightly_rate_cents" => 8_333}
          ]
        },
        overrides
      )
    )
  end

  defp transfer_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => @occurred_on,
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-25",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp cancel_rooms_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => @occurred_on,
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cb",
        "type" => "charge_back_payment",
        "occurred_on" => @occurred_on,
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp convert_cash_to_credit(group_id, operation_id, cash_cents, occurred_on) do
    [
      open_group_operation(%{"group_id" => group_id, "operation_id" => operation_id <> "-open"}),
      record_payment_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id <> "-pay",
        "amount_cents" => cash_cents
      }),
      cancel_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ]
  end

  defp assert_rejected(conn, code) do
    assert %{"results" => results} = json_response(conn, 200)
    result = List.last(results)

    assert result["status"] == "rejected"
    assert result["code"] == code
  end

  defp ledger(conn, opts \\ []) do
    query = if on = opts[:on], do: "?on=#{on}", else: ""
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger#{query}"), 200)
    data
  end
end
