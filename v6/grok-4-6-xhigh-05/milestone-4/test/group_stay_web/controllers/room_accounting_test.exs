defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups
  alias GroupStay.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "room-level accounting" do
    test "exposes room status, deposit, and fill-order cash on the group", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(5000)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 5000,
                 "outstanding_deposit_cents" => 14_500,
                 "cash_paid_cents" => 5000,
                 "credit_paid_cents" => 0,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "status" => "active",
                     "deposit_due_cents" => 9000,
                     "cash_paid_cents" => 5000,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "status" => "active",
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "fills one room's deposit before moving to the next", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(10_000)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 1000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "interleaves cash and credit in operation-processing order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          payment_op(4000, "group-82"),
          apply_credit_op(5500, "group-82")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 4000,
                 "credit_paid_cents" => 5500,
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

    test "allocates unattributed legacy funding before durable operations", %{conn: conn} do
      insert_funded_legacy_group("legacy-81", 7000)

      conn = get(conn, ~p"/api/v1/groups/legacy-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 7000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 7000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "pay-legacy-follow",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "legacy-81",
            "amount_cents" => 3000
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/legacy-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 10_000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 1000}
                 ]
               }
             } = json_response(conn, 200)
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms and returns ids in original group order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "cancel-b",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-b", "room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "operation_id" => "cancel-b",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "cancelled_room_ids" => ["room-a", "room-b"],
                   "refunded_cents" => 10_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

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

    test "leaves other rooms and their allocations unchanged", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "cancelled_room_ids" => ["room-a"],
                   "refunded_cents" => 9000,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 52_500,
                 "deposit_due_cents" => 10_500,
                 "deposit_paid_cents" => 1000,
                 "outstanding_deposit_cents" => 9500,
                 "cash_paid_cents" => 1000,
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
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 1000
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "computes hotel-credit bonus once on combined cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "group_id" => "g-bonus",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15},
              %{"room_id" => "room-b", "nightly_rate_cents" => 15}
            ]
          }),
          payment_op(6, "g-bonus"),
          %{
            "operation_id" => "cancel-combined",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "g-bonus",
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 7, "refunded_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "rejects invalid room selections without changing state", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          %{
            "operation_id" => "dup",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-a"]
          },
          %{
            "operation_id" => "missing",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-z"]
          },
          %{
            "operation_id" => "empty",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => []
          },
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "already",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "revision" => 2},
                 %{"status" => "rejected", "code" => "invalid_rooms"},
                 %{"status" => "rejected", "code" => "invalid_rooms"},
                 %{"status" => "rejected", "code" => "invalid_rooms"},
                 %{"status" => "applied", "revision" => 3},
                 %{"status" => "rejected", "code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 3, "status" => "active"}} = json_response(conn, 200)
    end

    test "rejects hotel credit when the cancellation is not refundable", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          %{
            "operation_id" => "late",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81",
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "rejected", "code" => "refund_method_not_available"}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "active", "revision" => 2}} = json_response(conn, 200)
    end

    test "retains cash for a non-refundable selected-room cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "cancel-late",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 9000,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 1000,
                 "cash_retained_cents" => 9000
               }
             } = json_response(conn, 200)
    end

    test "new funding after a room cancel fills remaining active rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          payment_op(2000)
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"status" => "applied", "outstanding_deposit_cents" => 7500}
               ]
             } =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 3000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "converts selected-room cash once and restores that room's credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          payment_op(4000, "group-82"),
          apply_credit_op(5500, "group-82"),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-82",
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 4400
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "status" => "active",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 500,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled"},
                   %{
                     "room_id" => "room-b",
                     "status" => "active",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 500
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 9400}} = json_response(conn, 200)
    end

    test "restores only the selected rooms' applied credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(10_000, "group-82"),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-82",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"credit_issued_cents" => 11_000},
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-82")

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

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 10_000}} = json_response(conn, 200)
    end

    test "cancel_group settles only remaining active rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          cancel_op("group-81", "2026-11-26")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 9000},
                 %{
                   "status" => "applied",
                   "refunded_cents" => 1000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000
               }
             } = json_response(conn, 200)
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-10000-group-81",
            "amount_cents" => 1500
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{"status" => "applied", "revision" => 2},
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "op-pay-10000-group-81",
                   "group_id" => "group-81",
                   "amount_cents" => 1500,
                   "outstanding_deposit_cents" => 11_000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 8500,
                 "outstanding_deposit_cents" => 11_000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 8500},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{"data" => %{"cash_held_cents" => 8500, "cash_reduced_cents" => 1500}} =
               json_response(conn, 200)
    end

    test "composes successive reductions against remaining held cash", %{conn: conn} do
      pay_id = "op-pay-10000-group-81"

      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => pay_id,
            "amount_cents" => 4000
          },
          %{
            "operation_id" => "reduce-2",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => pay_id,
            "amount_cents" => 6000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "outstanding_deposit_cents" => 13_500},
                 %{
                   "status" => "applied",
                   "amount_cents" => 6000,
                   "outstanding_deposit_cents" => 19_500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unusable reductions with the documented codes", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          %{
            "operation_id" => "no-op",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "ghost-pay",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "not-pay",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-1001",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "zero",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-1000-group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "over",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-1000-group-81",
            "amount_cents" => 1001
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "operation_not_found"},
                 %{"status" => "rejected", "code" => "payment_not_reducible"},
                 %{"status" => "rejected", "code" => "invalid_amount"},
                 %{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}
               ]
             } = json_response(conn, 200)
    end

    test "legacy funding cannot be targeted", %{conn: conn} do
      insert_funded_legacy_group("legacy-81", 5000)
      conn = get(conn, ~p"/api/v1/groups/legacy-81")
      assert %{"data" => %{"cash_paid_cents" => 5000}} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-legacy",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "never-recorded",
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "operation_not_found"}]
             } = json_response(conn, 200)
    end

    test "retrying the original payment returns its stored result without reapplying", %{
      conn: conn
    } do
      pay = payment_op(5000)

      conn = post_batch(conn, [open_group_op(), pay])
      original = json_response(conn, 200)["results"] |> Enum.at(1)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => pay["operation_id"],
            "amount_cents" => 2000
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [pay])
      assert hd(json_response(conn, 200)["results"]) == original

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"cash_paid_cents" => 3000, "revision" => 3}} = json_response(conn, 200)
    end

    test "settled cash cannot be reduced", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26"),
          %{
            "operation_id" => "reduce-settled",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-5000-group-81",
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "payment_not_reducible"}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "charge_back_payment" do
    test "charges back held cash and reopens outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "payment_operation_id" => "op-pay-5000-group-81",
                   "group_id" => "group-81",
                   "charged_back_cents" => 5000,
                   "outstanding_deposit_cents" => 19_500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_charged_back_cents" => 5000,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "reclassifies refunded cash without reversing the guest refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 5000},
                 %{
                   "status" => "applied",
                   "charged_back_cents" => 5000,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "revokes unspent credit entitlement and does not change the funded group", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(2000, "group-82"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 5500},
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "charged_back_cents" => 5000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-82")

      assert %{"data" => %{"credit_paid_cents" => 2000, "revision" => 2}} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 5000,
                 "credit_liability_cents" => 2000,
                 "credit_shortfall_cents" => 2000
               }
             } = json_response(conn, 200)
    end

    test "assigns telescoping entitlements when several payments fund one lot", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "group_id" => "g-tele",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50}]
          }),
          %{
            "operation_id" => "pay-3",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-tele",
            "amount_cents" => 3
          },
          %{
            "operation_id" => "pay-2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-tele",
            "amount_cents" => 2
          },
          cancel_op("g-tele", "2026-11-26", %{
            "operation_id" => "cancel-tele",
            "refund_method" => "hotel_credit"
          }),
          %{
            "operation_id" => "cb-pay-2",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-2"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 6},
                 %{"status" => "applied", "charged_back_cents" => 2}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 3}} = json_response(conn, 200)
    end

    test "absorbs restored credit into unrecovered clawback before expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(5500, "group-82"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-5000-group-81"
          },
          cancel_op("group-82", "2026-11-26", %{"operation_id" => "cancel-restore"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "charges back remaining cash after a reduction", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-5000-group-81",
            "amount_cents" => 1500
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied", "charged_back_cents" => 3500}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")

      assert %{
               "data" => %{
                 "recorded_cents" => 5000,
                 "held_cents" => 0,
                 "reduced_cents" => 1500,
                 "charged_back_cents" => 3500
               }
             } = json_response(conn, 200)
    end

    test "rejects unknown, non-payment, fully reduced, and repeat chargebacks", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          %{
            "operation_id" => "missing",
            "type" => "charge_back_payment",
            "payment_operation_id" => "ghost"
          },
          %{
            "operation_id" => "not-pay",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-1001"
          },
          %{
            "operation_id" => "reduce-all",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-1000-group-81",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cb-reduced",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-1000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "rejected", "code" => "operation_not_found"},
                 %{"status" => "rejected", "code" => "payment_not_chargeable"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "payment_not_chargeable"}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          payment_op(2000),
          %{
            "operation_id" => "cb-once",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-2000-group-81"
          },
          %{
            "operation_id" => "cb-twice",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-2000-group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "payment_not_chargeable"}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns the current disposition of an applied cash payment", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-5000-group-81",
            "amount_cents" => 500
          }
        ])

      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")
      body = json_response(conn, 200)

      assert body == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-5000-group-81",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5000,
                 "held_cents" => 4500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 500,
                 "charged_back_cents" => 0
               }
             }

      dispositions = body["data"]

      assert dispositions["held_cents"] + dispositions["refunded_cents"] +
               dispositions["retained_cents"] + dispositions["converted_to_credit_cents"] +
               dispositions["reduced_cents"] + dispositions["charged_back_cents"] ==
               dispositions["recorded_cents"]
    end

    test "returns 404 when no durable record exists", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/payments/missing")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "returns 422 when the record is not an applied cash payment", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-1001")
      assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)
    end

    test "agrees with room settlement of one payment across rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          payment_op(6000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{"results" => [_, _, _, %{"status" => "applied", "refunded_cents" => 9000}]} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")

      assert %{
               "data" => %{
                 "recorded_cents" => 5000,
                 "held_cents" => 0,
                 "refunded_cents" => 5000,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-6000-group-81")

      assert %{
               "data" => %{
                 "recorded_cents" => 6000,
                 "held_cents" => 2000,
                 "refunded_cents" => 4000,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "cash_paid_cents" => 2000,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled"},
                   %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 2000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "reading a statement never changes state", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(5000)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      before = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")
      assert %{"data" => %{"held_cents" => 5000}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 200) == before
    end
  end

  describe "durable idempotency of new operations" do
    test "replays cancel_rooms, reduce, and chargeback without repeating effects", %{conn: conn} do
      cancel_rooms = %{
        "operation_id" => "cancel-a",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      }

      conn = post_batch(conn, [open_group_op(), payment_op(10_000), cancel_rooms])
      original = json_response(conn, 200)["results"] |> List.last()

      conn = post_batch(conn, [cancel_rooms])
      assert hd(json_response(conn, 200)["results"]) == original

      reduce = %{
        "operation_id" => "reduce-b",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "op-pay-10000-group-81",
        "amount_cents" => 200
      }

      conn = post_batch(conn, [reduce])
      reduce_result = hd(json_response(conn, 200)["results"])
      assert reduce_result["status"] == "applied"

      conn = post_batch(conn, [reduce])
      assert hd(json_response(conn, 200)["results"]) == reduce_result

      conn = get(conn, ~p"/api/v1/groups/group-81")
      after_reduce = json_response(conn, 200)

      conn = post_batch(conn, [reduce])
      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 200) == after_reduce
    end

    test "stale revision is checked before reduction domain rules", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          %{
            "operation_id" => "stale-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-1000-group-81",
            "amount_cents" => 50_000,
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{"revision" => 2},
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => "op-pay-#{amount_cents}-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on, extras \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extras
    )
  end

  defp apply_credit_op(amount_cents, group_id, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => "op-credit-#{amount_cents}-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp insert_funded_legacy_group(group_id, cash_paid) do
    Repo.insert!(%Groups.Group{
      group_id: group_id,
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: ~D[2026-10-03],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-13],
      rate_plan: "flexible",
      status: "active",
      revision: 1,
      policy_version: "flex-14",
      lodging_total_cents: 97_500,
      deposit_due_cents: 19_500,
      deposit_paid_cents: cash_paid,
      outstanding_deposit_cents: 19_500 - cash_paid,
      refunded_cents: 0,
      retained_cents: 0,
      cash_paid_cents: cash_paid,
      credit_paid_cents: 0,
      cash_converted_to_credit_cents: 0
    })

    Repo.insert!(%Groups.Room{
      group_id: group_id,
      room_id: "room-a",
      nightly_rate_cents: 15_000,
      position: 0
    })

    Repo.insert!(%Groups.Room{
      group_id: group_id,
      room_id: "room-b",
      nightly_rate_cents: 17_500,
      position: 1
    })
  end

  defp post_batch(conn, operations) do
    post_json(conn, ~p"/api/v1/partner-batches", %{operations: operations})
  end

  defp post_json(conn, path, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
