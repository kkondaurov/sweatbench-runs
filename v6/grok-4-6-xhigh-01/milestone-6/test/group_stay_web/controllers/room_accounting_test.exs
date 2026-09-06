defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  describe "room-level accounting" do
    test "funds rooms in original order and exposes room fields", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), pay_op(10_000)])

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]

      assert data["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 9000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 1000,
                 "credit_paid_cents" => 0
               }
             ]

      assert data["deposit_due_cents"] == 19_500
      assert data["cash_paid_cents"] == 10_000
      assert data["outstanding_deposit_cents"] == 9500
    end

    test "applies credit after cash while filling rooms in order", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(8000), %{"group_id" => "group-82", "operation_id" => "pay-2"}),
          credit_op("apply-1", "group-82", 4000, "2026-11-02")
        ])

      conn = get(conn, "/api/v1/groups/group-82")
      rooms = json_response(conn, 200)["data"]["rooms"]

      assert Enum.at(rooms, 0)["cash_paid_cents"] == 8000
      assert Enum.at(rooms, 0)["credit_paid_cents"] == 1000
      assert Enum.at(rooms, 1)["cash_paid_cents"] == 0
      assert Enum.at(rooms, 1)["credit_paid_cents"] == 3000
    end

    test "brings pre-durable funding forward as a senior unattributed block", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op()])

      {1, _} = Repo.update_all(Group, set: [cash_paid_cents: 12_000, deposit_paid_cents: 12_000])

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]

      assert Enum.at(data["rooms"], 0)["cash_paid_cents"] == 9000
      assert Enum.at(data["rooms"], 1)["cash_paid_cents"] == 3000
      assert data["cash_paid_cents"] == 12_000
      assert data["outstanding_deposit_cents"] == 7500

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 12_000

      conn = get(conn, "/api/v1/payments/missing-legacy")
      assert json_response(conn, 404)["error"]["code"] == "operation_not_found"
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms and leaves the others unchanged", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(12_000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "cancel-a",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 9000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 3
      assert data["lodging_total_cents"] == 52_500
      assert data["deposit_due_cents"] == 10_500
      assert data["cash_paid_cents"] == 3000
      assert data["outstanding_deposit_cents"] == 7500

      assert Enum.at(data["rooms"], 0)["status"] == "cancelled"
      assert Enum.at(data["rooms"], 0)["cash_paid_cents"] == 0
      assert Enum.at(data["rooms"], 1)["status"] == "active"
      assert Enum.at(data["rooms"], 1)["cash_paid_cents"] == 3000
    end

    test "cancelling the last active rooms cancels the group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(19_500),
          %{
            "operation_id" => "cancel-both",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-b", "room-a"]
          }
        ])

      assert [
               _,
               _,
               %{
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "refunded_cents" => 19_500,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["lodging_total_cents"] == 0
      assert data["deposit_due_cents"] == 0
      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0
    end

    test "computes a hotel-credit bonus once on combined selected cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 25},
              %{"room_id" => "room-b", "nightly_rate_cents" => 25}
            ],
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11"
          }),
          pay_op(10),
          %{
            "operation_id" => "cancel-credit",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert [
               %{"deposit_due_cents" => 10},
               _,
               %{"credit_issued_cents" => 11, "refunded_cents" => 0, "retained_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end

    test "cancel_group settles only remaining active rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(12_000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          cancel_op("cancel-rest", "2026-11-02")
        ])

      assert [
               _,
               _,
               %{"refunded_cents" => 9000},
               %{
                 "operation_id" => "cancel-rest",
                 "refunded_cents" => 3000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["status"] == "cancelled"

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_refunded_cents"] == 12_000
      assert ledger["cash_held_cents"] == 0
    end

    test "rejects invalid room selections", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "dup",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-a"]
          },
          %{
            "operation_id" => "unknown",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-z"]
          },
          %{
            "operation_id" => "empty",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => []
          },
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "already",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => "dup", "code" => "invalid_rooms"},
               %{"operation_id" => "unknown", "code" => "invalid_rooms"},
               %{"operation_id" => "empty", "code" => "invalid_rooms"},
               %{"status" => "applied"},
               %{"operation_id" => "already", "code" => "invalid_rooms"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects hotel credit when the group is not refundable", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(9000),
          %{
            "operation_id" => "late",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81",
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert [
               _,
               %{"revision" => 2},
               %{"code" => "refund_method_not_available"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["status"] == "active"
      assert json_response(conn, 200)["data"]["revision"] == 2
    end

    test "checks stale revision before invalid rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-rooms",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["missing"],
            "expected_revision" => 1
          }
        ])

      assert [
               _,
               _,
               %{
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2,
                 "group_id" => "group-81"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "is durably idempotent", %{conn: conn} do
      op = %{
        "operation_id" => "cancel-a",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      }

      first = post_batch(conn, [open_op(), pay_op(9000), op])
      original = List.last(json_response(first, 200)["results"])

      retry = post_batch(conn, [op])
      assert List.last(json_response(retry, 200)["results"]) == original

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 3
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(12_000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 4000
          }
        ])

      assert [
               _,
               _,
               %{
                 "operation_id" => "reduce-1",
                 "status" => "applied",
                 "payment_operation_id" => "op-pay",
                 "group_id" => "group-81",
                 "amount_cents" => 4000,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert Enum.at(data["rooms"], 0)["cash_paid_cents"] == 8000
      assert Enum.at(data["rooms"], 1)["cash_paid_cents"] == 0
      assert data["cash_paid_cents"] == 8000
      assert data["outstanding_deposit_cents"] == 11_500

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 8000
      assert ledger["cash_reduced_cents"] == 4000
    end

    test "composes successive reductions including the remaining held amount", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "reduce-2",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 3000
          }
        ])

      assert [
               _,
               _,
               %{"status" => "applied", "revision" => 3},
               %{"status" => "applied", "outstanding_deposit_cents" => 19_500, "revision" => 4}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 5000,
               "charged_back_cents" => 0
             }
    end

    test "rejects unusable reductions", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "missing",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "no-such",
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
            "payment_operation_id" => "op-pay",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "over",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1001
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "operation_not_found"},
               %{"code" => "payment_not_reducible"},
               %{"code" => "invalid_amount"},
               %{"code" => "reduction_exceeds_held_cash"}
             ] = json_response(conn, 200)["results"]
    end

    test "checks stale revision before other reduce rules", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 99_999,
            "expected_revision" => 1
          }
        ])

      assert [
               _,
               _,
               %{
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "does not move settled cash and leaves the original payment result unchanged", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(9000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "reduce-settled",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 100
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["code"] == "payment_not_reducible"

      retry = post_batch(conn, [pay_op(9000)])

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "amount_cents" => 9000,
                 "outstanding_deposit_cents" => 10_500,
                 "revision" => 2
               }
             ] = json_response(retry, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 0
    end
  end

  describe "charge_back_payment" do
    test "reclassifies held cash and reopens outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert [
               _,
               _,
               %{
                 "payment_operation_id" => "op-pay",
                 "group_id" => "group-81",
                 "charged_back_cents" => 5000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000

      conn = get(conn, "/api/v1/payments/op-pay")
      statement = json_response(conn, 200)["data"]
      assert statement["held_cents"] == 0
      assert statement["charged_back_cents"] == 5000
      assert statement["recorded_cents"] == 5000
    end

    test "reclassifies refunded cash without reversing the guest refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-1", "2026-11-01"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert [
               _,
               _,
               %{"refunded_cents" => 5000},
               %{"charged_back_cents" => 5000, "revision" => 4}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["revision"] == 4

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "revokes converted credit entitlement and records shortfall", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("apply-1", "group-82", 4000, "2026-11-02"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["charged_back_cents"] == 5000

      conn = get(conn, "/api/v1/groups/group-82")
      funded = json_response(conn, 200)["data"]
      assert funded["revision"] == 2
      assert funded["credit_paid_cents"] == 4000

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 4

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-02")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2026-11-02")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
      assert ledger["credit_shortfall_cents"] == 4000
      assert ledger["credit_liability_cents"] == 4000
    end

    test "telescopes entitlements across payments in one lot", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
          }),
          pay_op(5),
          Map.merge(pay_op(5), %{"operation_id" => "pay-2"}),
          cancel_op("cancel-lot", "2026-11-01", "hotel_credit"),
          %{
            "operation_id" => "cb-first",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")
      assert json_response(conn, 200)["data"]["available_cents"] == 5

      conn = get(conn, "/api/v1/ledger?on=2026-11-01")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_charged_back_cents"] == 5
      assert ledger["cash_converted_to_credit_cents"] == 5
      assert ledger["credit_liability_cents"] == 5
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "absorbs restored credit into unrecovered clawback before expiry", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{
            "operation_id" => "open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          credit_op("apply-1", "group-82", 4000, "2026-11-02"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          Map.merge(cancel_op("cancel-82", "2027-11-02"), %{"group_id" => "group-82"})
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-02")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2027-11-02")
      ledger = json_response(conn, 200)["data"]
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end

    test "non-refundable consumption of applied credit clears the current shortfall", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("apply-1", "group-82", 4000, "2026-11-02"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          Map.merge(cancel_op("late-82", "2026-12-01"), %{"group_id" => "group-82"})
        ])

      conn = get(conn, "/api/v1/ledger?on=2026-12-01")
      ledger = json_response(conn, 200)["data"]
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end

    test "charges back remaining cash after a partial reduction", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "cb-rest",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["charged_back_cents"] == 3000

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2000,
               "charged_back_cents" => 3000
             }
    end

    test "restored credit leftover becomes available after absorbing clawback", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
          }),
          pay_op(5),
          Map.merge(pay_op(5), %{"operation_id" => "pay-2"}),
          cancel_op("cancel-lot", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("apply-1", "group-82", 8, "2026-11-02"),
          %{
            "operation_id" => "cb-first",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          Map.merge(cancel_op("cancel-82", "2026-11-03"), %{"group_id" => "group-82"})
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-03")
      assert json_response(conn, 200)["data"]["available_cents"] == 5

      conn = get(conn, "/api/v1/ledger?on=2026-11-03")
      ledger = json_response(conn, 200)["data"]
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 5
    end

    test "revokes entitlement independently on each lot a payment funded", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(19_500),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "cancel-b",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-b"],
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]
      assert data["converted_to_credit_cents"] == 0
      assert data["charged_back_cents"] == 19_500
    end

    test "checks stale revision before payment_not_chargeable", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "cb-once",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          %{
            "operation_id" => "cb-stale",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay",
            "expected_revision" => 2
          }
        ])

      assert [
               _,
               _,
               %{"status" => "applied", "revision" => 3},
               %{"code" => "stale_revision", "expected_revision" => 2, "actual_revision" => 3}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a second chargeback and a fully reduced payment", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "reduce-all",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cb-reduced",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(1000), %{"group_id" => "group-82", "operation_id" => "pay-2"}),
          %{
            "operation_id" => "cb-once",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-2"
          },
          %{
            "operation_id" => "cb-again",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-2"
          },
          %{
            "operation_id" => "cb-missing",
            "type" => "charge_back_payment",
            "payment_operation_id" => "no-such"
          },
          %{
            "operation_id" => "cb-open",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-1001"
          }
        ])

      results = json_response(conn, 200)["results"]

      assert Enum.at(results, 3)["code"] == "payment_not_chargeable"
      assert Enum.at(results, 6)["status"] == "applied"
      assert Enum.at(results, 7)["code"] == "payment_not_chargeable"
      assert Enum.at(results, 8)["code"] == "operation_not_found"
      assert Enum.at(results, 9)["code"] == "payment_not_chargeable"
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns current dispositions that sum to recorded cash", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(12_000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          }
        ])

      conn = get(conn, "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]

      assert data == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 2000,
               "refunded_cents" => 9000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             }

      assert data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
               data["converted_to_credit_cents"] + data["reduced_cents"] +
               data["charged_back_cents"] == data["recorded_cents"]
    end

    test "returns the usual errors for missing or non-payment records", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op()])

      conn = get(conn, "/api/v1/payments/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      conn = get(conn, "/api/v1/payments/op-1001")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end

  defp open_and_return(conn, operations) do
    conn = post_batch(conn, operations)
    assert conn.status == 200
    {:ok, conn}
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_op(overrides \\ %{}) do
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

  defp pay_op(amount_cents) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, occurred_on, refund_method \\ nil) do
    op = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-81"
    }

    if refund_method, do: Map.put(op, "refund_method", refund_method), else: op
  end

  defp credit_op(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
