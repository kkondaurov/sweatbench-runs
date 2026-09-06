defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Accounting
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  describe "room-level accounting" do
    test "exposes room status, deposit, and waterfall funding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 10000),
          cash_payment_op("pay-2", 5000)
        ])

      assert %{"results" => [_, %{"status" => "applied"}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 15000,
                 "cash_paid_cents" => 15000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 4500,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15000,
                     "status" => "active",
                     "deposit_due_cents" => 9000,
                     "cash_paid_cents" => 9000,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17500,
                     "status" => "active",
                     "deposit_due_cents" => 10500,
                     "cash_paid_cents" => 6000,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "allocates credit after cash in original room order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("pay-2", 4000, "group-82"),
          apply_credit_op("op-credit", 5500, "group-82")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 4000,
                 "credit_paid_cents" => 5500,
                 "deposit_paid_cents" => 9500,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 4000,
                     "credit_paid_cents" => 5000
                   },
                   %{
                     "room_id" => "room-b",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 500
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "brings legacy funding forward as an unattributed senior block", %{conn: conn} do
      {:ok, group} =
        %Group{}
        |> Group.changeset(%{
          group_id: "group-legacy-pay",
          guest_id: "guest-22",
          property_id: "ams-canal",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          policy_version: "flex-14",
          status: "active",
          revision: 2,
          lodging_total_cents: 97500,
          deposit_due_cents: 19500,
          deposit_paid_cents: 12000,
          cash_paid_cents: 12000,
          credit_paid_cents: 0
        })
        |> Ecto.Changeset.put_assoc(:rooms, [
          %Room{room_id: "room-a", nightly_rate_cents: 15000, position: 0},
          %Room{room_id: "room-b", nightly_rate_cents: 17500, position: 1}
        ])
        |> Repo.insert()

      Accounting.Backfill.backfill_group(group)

      conn =
        post_batch(conn, [
          cash_payment_op("pay-new", 3000, "group-legacy-pay")
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-legacy-pay")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 15000,
                 "outstanding_deposit_cents" => 4500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 6000}
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-new")

      assert %{
               "data" => %{
                 "held_cents" => 3000,
                 "recorded_cents" => 3000,
                 "reduced_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")
      assert %{"data" => %{"cash_held_cents" => 15000}} = json_response(conn, 200)
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms and keeps others unchanged", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 12000),
          %{
            "operation_id" => "cancel-rooms-1",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-b", "room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "cancelled_room_ids" => ["room-a", "room-b"],
                   "refunded_cents" => 12000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "lodging_total_cents" => 0,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "cancels one room and recomputes active totals", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 12000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "cancelled_room_ids" => ["room-a"],
                   "refunded_cents" => 9000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 52500,
                 "deposit_due_cents" => 10500,
                 "cash_paid_cents" => 3000,
                 "outstanding_deposit_cents" => 7500,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "cancelled",
                     "deposit_due_cents" => 9000,
                     "cash_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "active",
                     "deposit_due_cents" => 10500,
                     "cash_paid_cents" => 3000
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 3000,
                 "cash_refunded_cents" => 9000
               }
             } = json_response(conn, 200)
    end

    test "computes hotel-credit bonus once on combined cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 10),
          %{
            "operation_id" => "cancel-rooms-credit",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"credit_issued_cents" => 11, "refunded_cents" => 0, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "rejects invalid room selections without changing state", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-dup",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-a"]
          },
          %{
            "operation_id" => "cancel-missing",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-z"]
          },
          %{
            "operation_id" => "cancel-empty",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => []
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "rejected", "code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "status" => "active",
                 "cash_paid_cents" => 5000,
                 "rooms" => [
                   %{"status" => "active"},
                   %{"status" => "active"}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "rejects already cancelled rooms and hotel_credit when non-refundable", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 12000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "cancel-a-again",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "cancel-late",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-12-09",
            "group_id" => "group-81",
            "room_ids" => ["room-b"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"code" => "invalid_rooms"},
                 %{"code" => "refund_method_not_available"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "active", "revision" => 3}} = json_response(conn, 200)
    end

    test "cancel_group settles only remaining active rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 12000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "cancel-rest",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"refunded_cents" => 9000},
                 %{
                   "status" => "applied",
                   "refunded_cents" => 3000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{"data" => %{"cash_held_cents" => 0, "cash_refunded_cents" => 12000}} =
               json_response(conn, 200)
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 12000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 4000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "pay-17",
                   "group_id" => "group-81",
                   "amount_cents" => 4000,
                   "outstanding_deposit_cents" => 11500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 8000,
                 "outstanding_deposit_cents" => 11500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 8000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "payment_operation_id" => "pay-17",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 12000,
                 "held_cents" => 8000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 4000,
                 "charged_back_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 8000,
                 "cash_reduced_cents" => 4000
               }
             } = json_response(conn, 200)
    end

    test "composes successive reductions and accepts the remaining held amount", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "reduce-2",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 3000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "amount_cents" => 2000},
                 %{
                   "status" => "applied",
                   "amount_cents" => 3000,
                   "outstanding_deposit_cents" => 19500
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")
      assert %{"data" => %{"held_cents" => 0, "reduced_cents" => 5000}} = json_response(conn, 200)
    end

    test "uses the documented rejection codes", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "reduce-missing",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "no-such-pay",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "reduce-open",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "op-1001",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "reduce-zero",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "reduce-over",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 5001
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"code" => "operation_not_found"},
                 %{"code" => "payment_not_reducible"},
                 %{"code" => "invalid_amount"},
                 %{"code" => "reduction_exceeds_held_cash"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5000}} = json_response(conn, 200)
    end

    test "does not rewrite the original payment result", %{conn: conn} do
      payment = cash_payment_op("pay-17", 5000)

      conn =
        post_batch(conn, [
          open_group_op(),
          payment,
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 1000
          },
          payment
        ])

      assert %{
               "results" => [
                 _,
                 %{"amount_cents" => 5000, "outstanding_deposit_cents" => 14500, "revision" => 2},
                 %{"amount_cents" => 1000, "revision" => 3},
                 %{"amount_cents" => 5000, "outstanding_deposit_cents" => 14500, "revision" => 2}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 4000}} = json_response(conn, 200)
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash and reopens the deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
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
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "pay-17",
                   "group_id" => "group-81",
                   "charged_back_cents" => 5000,
                   "outstanding_deposit_cents" => 19500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "charged_back_cents" => 5000,
                 "recorded_cents" => 5000
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_charged_back_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "reclassifies refunded cash without reversing the guest refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "cancel-1",
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
                 %{"refunded_cents" => 5000, "revision" => 3},
                 %{
                   "charged_back_cents" => 5000,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 5000
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "cancelled", "revision" => 4}} = json_response(conn, 200)
    end

    test "claws back converted credit using telescoping entitlements", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5),
          cash_payment_op("pay-2", 5),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-1"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"credit_issued_cents" => 11},
                 %{"charged_back_cents" => 5, "revision" => 5}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 5}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 5,
                 "cash_charged_back_cents" => 5,
                 "credit_liability_cents" => 5,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "records shortfall when applied credit cannot be clawed back", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-credit", 5500, "group-82"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-1"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert List.last(results)["revision"] == 4

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "credit_paid_cents" => 5500,
                 "status" => "active"
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 5500,
                 "credit_shortfall_cents" => 5500,
                 "cash_charged_back_cents" => 5000,
                 "cash_converted_to_credit_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "absorbs restored credit into unrecovered clawback before expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          apply_credit_op("op-credit", 2000, "group-82"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-1"
          },
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2027-11-02",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "non-refundable credit settlement reduces shortfall", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-credit", 2000, "group-82"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-1"
          },
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-09",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "credit_shortfall_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "rejects unchargeable targets and leaves reduced cash in place", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "reduce-all",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cb-reduced",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "pay-17"
          },
          %{
            "operation_id" => "cb-missing",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "missing-pay"
          },
          %{
            "operation_id" => "cb-open",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "op-1001"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"code" => "payment_not_chargeable"},
                 %{"code" => "operation_not_found"},
                 %{"code" => "payment_not_chargeable"}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns current dispositions that sum to recorded cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 1000
          }
        ])

      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")
      body = json_response(conn, 200)

      assert body == %{
               "data" => %{
                 "payment_operation_id" => "pay-17",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5000,
                 "held_cents" => 4000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1000,
                 "charged_back_cents" => 0
               }
             }

      data = body["data"]

      assert data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
               data["converted_to_credit_cents"] + data["reduced_cents"] +
               data["charged_back_cents"] == data["recorded_cents"]
    end

    test "returns 404 and 422 for unreadable targets", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/missing-pay")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)

      conn = get_json(conn, ~p"/api/v1/payments/op-1001")
      assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)
    end

    test "does not change state when read", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), cash_payment_op("pay-17", 5000)])
      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")
      assert %{"data" => %{"held_cents" => 5000}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5000}} = json_response(conn, 200)
    end
  end

  describe "mixed settlement and revisions" do
    test "cancel_rooms restores only the selected rooms' credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 10000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-credit", 10000, "group-82"),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-82",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "status" => "active",
                 "credit_paid_cents" => 1000,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "credit_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "active", "credit_paid_cents" => 1000}
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 10000}} = json_response(conn, 200)
    end

    test "charges back remaining cash after a partial reduction", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 2000
          },
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
                 %{"status" => "applied"},
                 %{"charged_back_cents" => 3000, "revision" => 4}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/payments/pay-17")

      assert %{
               "data" => %{
                 "recorded_cents" => 5000,
                 "held_cents" => 0,
                 "reduced_cents" => 2000,
                 "charged_back_cents" => 3000
               }
             } = json_response(conn, 200)
    end

    test "rejects a stale revision before payment reduction rules", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), cash_payment_op("pay-17", 5000)])
      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-stale",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 100,
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2,
                   "group_id" => "group-81"
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5000}} = json_response(conn, 200)
    end

    test "makes only excess restored credit available after absorbing shortfall", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-1", 5),
          cash_payment_op("pay-2", 5),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-credit", 10, "group-82"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-1"
          },
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-03",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 5}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "credit_shortfall_cents" => 0,
                 "credit_liability_cents" => 5
               }
             } = json_response(conn, 200)
    end
  end

  describe "durable idempotency for new operations" do
    test "replays cancel_rooms, reduce, and chargeback results", %{conn: conn} do
      cancel_rooms = %{
        "operation_id" => "cancel-a",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      }

      reduce = %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "pay-b",
        "amount_cents" => 500
      }

      chargeback = %{
        "operation_id" => "cb-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "pay-b"
      }

      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-a", 9000),
          cash_payment_op("pay-b", 3000),
          cancel_rooms,
          reduce,
          chargeback
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = post_batch(conn, [cancel_rooms, reduce, chargeback])
      assert %{"results" => replayed} = json_response(conn, 200)
      assert replayed == Enum.take(results, -3)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 6, "status" => "active"}} = json_response(conn, 200)
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
end
