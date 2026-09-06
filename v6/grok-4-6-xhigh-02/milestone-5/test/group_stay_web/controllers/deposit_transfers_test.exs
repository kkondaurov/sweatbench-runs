defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  describe "transfer_deposit" do
    test "moves held cash between active groups of the same guest", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 10000),
          open_group_op(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          transfer_op("xfer-1", 4000)
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{
                   "operation_id" => "xfer-1",
                   "status" => "applied",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-92",
                   "amount_cents" => 4000,
                   "source_outstanding_deposit_cents" => 13500,
                   "destination_outstanding_deposit_cents" => 15500,
                   "source_revision" => 3,
                   "destination_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 3,
                 "cash_paid_cents" => 6000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 13500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 6000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "cash_paid_cents" => 4000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 15500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 4000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "peels mixed funding in reverse allocation order and fills dest rooms in draw order", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-src", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-82", "group_id" => "group-82"}),
          cash_payment_op("pay-82", 4000, "group-82"),
          apply_credit_op("credit-82", 5500, "group-82"),
          open_group_op(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "rooms" => [
              %{"room_id" => "room-x", "nightly_rate_cents" => 1000},
              %{"room_id" => "room-y", "nightly_rate_cents" => 15000}
            ]
          }),
          transfer_op("xfer-mix", 600, "group-82", "group-92")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert List.last(results)["amount_cents"] == 600

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 4000,
                 "credit_paid_cents" => 4900,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 4000,
                     "credit_paid_cents" => 4900
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 600,
                 "rooms" => [
                   %{
                     "room_id" => "room-x",
                     "deposit_due_cents" => 600,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 600
                   },
                   %{
                     "room_id" => "room-y",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "does not change ledger totals or resume credit expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-src", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-82", "group_id" => "group-82"}),
          cash_payment_op("pay-82", 3000, "group-82"),
          apply_credit_op("credit-82", 2000, "group-82"),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 2500, "group-82", "group-92")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 3000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, "/api/v1/ledger?on=2027-11-02")
      assert %{"data" => %{"credit_liability_cents" => 2000}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 3500}} = json_response(conn, 200)
    end

    test "settles transferred cash under the destination policy and bonus", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{
            "operation_id" => "op-open-ap",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          }),
          transfer_op("xfer-ap", 2000, "group-81", "group-ap"),
          %{
            "operation_id" => "cancel-ap",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-ap"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"refunded_cents" => 0, "retained_cents" => 2000, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-flex", 3000, "group-81", "group-92"),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-92",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{"status" => "applied", "amount_cents" => 3000},
                 %{
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 3300
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "retained_cents" => 2000,
                 "converted_to_credit_cents" => 3000,
                 "recorded_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "restores transferred credit to its original lot without a second bonus", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-src", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-82", "group_id" => "group-82"}),
          apply_credit_op("credit-82", 2000, "group-82"),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-credit", 2000, "group-82", "group-92"),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-92",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => results
             } = json_response(conn, 200)

      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert List.last(results)["credit_issued_cents"] == 0
      assert List.last(results)["refunded_cents"] == 0

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 5500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "uses the documented rejection codes and validation order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{
            "operation_id" => "op-open-other",
            "group_id" => "group-other",
            "guest_id" => "guest-99"
          }),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-92"
          },
          open_group_op(%{
            "operation_id" => "op-open-93",
            "group_id" => "group-93",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn =
        post_batch(conn, [
          transfer_op("xfer-missing-src", 100, "missing-src", "group-92"),
          transfer_op("xfer-missing-dst", 100, "group-81", "missing-dst"),
          transfer_op("xfer-same", 100, "group-81", "group-81"),
          transfer_op("xfer-guest", 100, "group-81", "group-other"),
          transfer_op("xfer-inactive", 100, "group-81", "group-92"),
          Map.merge(transfer_op("xfer-zero", 0, "group-81", "group-93"), %{
            "amount_cents" => 0
          }),
          transfer_op("xfer-held", 5001, "group-81", "group-93"),
          cash_payment_op("pay-93", 8500, "group-93"),
          transfer_op("xfer-out", 5000, "group-81", "group-93")
        ])

      assert %{
               "results" => [
                 %{
                   "code" => "group_not_found",
                   "group_id" => "missing-src"
                 },
                 %{
                   "code" => "group_not_found",
                   "group_id" => "missing-dst"
                 },
                 %{"code" => "invalid_transfer"},
                 %{"code" => "invalid_transfer"},
                 %{"code" => "group_not_active", "group_id" => "group-92"},
                 %{"code" => "invalid_amount"},
                 %{"code" => "transfer_exceeds_held_funding"},
                 %{"status" => "applied"},
                 %{"code" => "transfer_exceeds_outstanding"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5000}} = json_response(conn, 200)
    end

    test "checks source then destination revisions before transfer rules", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"})
        ])

      assert %{"results" => [_, %{"revision" => 2}, %{"revision" => 1}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          Map.merge(transfer_op("xfer-src-stale", 100), %{
            "expected_revision" => 1,
            "destination_expected_revision" => 0
          })
        ])

      assert %{
               "results" => [
                 %{
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          Map.merge(transfer_op("xfer-dst-stale", 100), %{
            "expected_revision" => 2,
            "destination_expected_revision" => 0
          })
        ])

      assert %{
               "results" => [
                 %{
                   "code" => "stale_revision",
                   "group_id" => "group-92",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          Map.merge(transfer_op("xfer-ok", 100), %{
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "source_revision" => 3,
                   "destination_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "prefers invalid_transfer over inactive when groups are the same", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "cancel-81",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          transfer_op("xfer-same-inactive", 100, "group-81", "group-81")
        ])

      assert %{"results" => [_, _, %{"code" => "invalid_transfer"}]} = json_response(conn, 200)
    end

    test "fills remaining destination capacity in original room order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 12000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          cash_payment_op("pay-92", 3000, "group-92"),
          transfer_op("xfer-1", 7000)
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 10000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 1000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "rejects an inactive source with that group_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "cancel-81",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-inactive-src", 100)
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"code" => "group_not_active", "group_id" => "group-81"}
               ]
             } = json_response(conn, 200)
    end

    test "sees earlier same-batch transfers when checking destination revision", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          Map.put(transfer_op("xfer-1", 1000), "destination_expected_revision", 1),
          Map.put(transfer_op("xfer-2", 1000), "destination_expected_revision", 1)
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"status" => "applied", "destination_revision" => 2},
                 %{
                   "code" => "stale_revision",
                   "group_id" => "group-92",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "replays an exact retry without moving funding again", %{conn: conn} do
      transfer = transfer_op("xfer-1", 4000)

      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 10000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer
        ])

      assert %{"results" => results} = json_response(conn, 200)
      applied = List.last(results)
      assert applied["status"] == "applied"

      conn = post_batch(conn, [transfer, transfer])
      assert %{"results" => [first, second]} = json_response(conn, 200)
      assert first == applied
      assert second == applied

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 6000}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-92")
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 4000}} = json_response(conn, 200)
    end
  end

  describe "reductions and chargebacks after transfers" do
    test "follow a payment across groups and increment every changed group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 10000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 4000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 5000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 4,
                 "cash_paid_cents" => 5000,
                 "outstanding_deposit_cents" => 14500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "revision" => 3,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 5000,
                 "reduced_cents" => 5000,
                 "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 5000}]
               }
             } = json_response(conn, 200)
    end

    test "chargeback peels transferred held cash and keeps result revision on the original group",
         %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 2000),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "pay-17"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "charged_back_cents" => 5000,
                   "group_id" => "group-81",
                   "outstanding_deposit_cents" => 19500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-92")
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 0}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "charged_back_cents" => 5000,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)
    end

    test "chargeback after source settlement still peels dest-held cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 2000),
          %{
            "operation_id" => "cancel-81",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-17"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"refunded_cents" => 3000, "revision" => 4},
                 %{
                   "charged_back_cents" => 5000,
                   "group_id" => "group-81",
                   "outstanding_deposit_cents" => 0,
                   "revision" => 5
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-92")
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 0}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "charged_back_cents" => 5000,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "does not rewrite the original payment result after a transfer", %{conn: conn} do
      payment = cash_payment_op("pay-17", 5000)

      conn =
        post_batch(conn, [
          open_group_op(),
          payment,
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 2000),
          payment
        ])

      assert %{
               "results" => [
                 _,
                 %{"amount_cents" => 5000, "outstanding_deposit_cents" => 14500, "revision" => 2},
                 _,
                 %{"status" => "applied"},
                 %{"amount_cents" => 5000, "outstanding_deposit_cents" => 14500, "revision" => 2}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 3000}} = json_response(conn, 200)
    end
  end

  describe "payment statements after transfers" do
    test "adds held_by_group only after a payment participates in a transfer", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), cash_payment_op("pay-17", 10000)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")
      body = json_response(conn, 200)
      refute Map.has_key?(body["data"], "held_by_group")

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 4000)
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 10000,
                 "held_by_group" => [
                   %{"group_id" => "group-81", "amount_cents" => 6000},
                   %{"group_id" => "group-92", "amount_cents" => 4000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "omits groups with no held cash and returns an empty list once none remains", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-1", 2000),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-92"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 3000,
                 "refunded_cents" => 2000,
                 "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 3000}]
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-81",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 5000,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)
    end

    test "does not add held_by_group when only hotel credit is transferred", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-src", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-82", "group_id" => "group-82"}),
          apply_credit_op("credit-82", 2000, "group-82"),
          open_group_op(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
          transfer_op("xfer-credit", 2000, "group-82", "group-92")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/payments/pay-src")
      body = json_response(conn, 200)
      refute Map.has_key?(body["data"], "held_by_group")
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp get_json(conn, path) do
    conn
    |> recycle()
    |> get(path)
  end

  defp open_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1001",
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

  defp cash_payment_op(operation_id, amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_op(operation_id, amount_cents, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(
         operation_id,
         amount_cents,
         source_group_id \\ "group-81",
         destination_group_id \\ "group-92"
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-05",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end
end
