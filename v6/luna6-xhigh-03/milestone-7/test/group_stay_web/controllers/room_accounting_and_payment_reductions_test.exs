defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(group_id, rooms, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: "guest-room-test",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: rooms
      },
      overrides
    )
  end

  test "funding fills rooms in order and cancel_rooms settles only the selected room", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_operation("room-block", [
          %{room_id: "room-a", nightly_rate_cents: 25},
          %{room_id: "room-b", nightly_rate_cents: 25}
        ]),
        %{
          operation_id: "room-block-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "room-block",
          amount_cents: 7
        },
        %{
          operation_id: "cancel-room-b",
          type: "cancel_rooms",
          occurred_on: "2026-10-05",
          group_id: "room-block",
          room_ids: ["room-b"]
        }
      ])

    assert Enum.at(results, 2) == %{
             "operation_id" => "cancel-room-b",
             "status" => "applied",
             "group_id" => "room-block",
             "cancelled_room_ids" => ["room-b"],
             "refunded_cents" => 2,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    group =
      conn
      |> get("/api/v1/groups/room-block")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["lodging_total_cents"] == 25
    assert group["deposit_due_cents"] == 5
    assert group["deposit_paid_cents"] == 5
    assert group["cash_paid_cents"] == 5
    assert group["outstanding_deposit_cents"] == 0

    assert group["rooms"] == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 25,
               "status" => "active",
               "deposit_due_cents" => 5,
               "cash_paid_cents" => 5,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 25,
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert conn
           |> get("/api/v1/payments/room-block-payment")
           |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "room-block-payment",
               "original_group_id" => "room-block",
               "recorded_cents" => 7,
               "held_cents" => 5,
               "refunded_cents" => 2,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }
  end

  test "cancel_rooms preserves original order and rounds one bonus for the combined cash", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_operation("rounding-block", [
          %{room_id: "room-a", nightly_rate_cents: 25},
          %{room_id: "room-b", nightly_rate_cents: 25}
        ]),
        %{
          operation_id: "rounding-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "rounding-block",
          amount_cents: 10
        },
        %{
          operation_id: "rounding-cancel",
          type: "cancel_rooms",
          occurred_on: "2026-10-05",
          group_id: "rounding-block",
          room_ids: ["room-b", "room-a"],
          refund_method: "hotel_credit"
        }
      ])

    assert Enum.at(results, 2) == %{
             "operation_id" => "rounding-cancel",
             "status" => "applied",
             "group_id" => "rounding-block",
             "cancelled_room_ids" => ["room-a", "room-b"],
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 11,
             "revision" => 3
           }

    assert conn
           |> get("/api/v1/guests/guest-room-test/credit?on=2026-10-05")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 11

    group =
      conn
      |> get("/api/v1/groups/rounding-block")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["status"] == "cancelled"
    assert group["lodging_total_cents"] == 0
    assert group["deposit_due_cents"] == 0
    assert group["deposit_paid_cents"] == 0
  end

  test "reductions target held cash and chargebacks create and absorb credit shortfall", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_operation(
          "source-group",
          [%{room_id: "source-room", nightly_rate_cents: 1010}]
        ),
        %{
          operation_id: "cash-payment-a",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "source-group",
          amount_cents: 101
        },
        %{
          operation_id: "cash-payment-b",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "source-group",
          amount_cents: 101
        },
        %{
          operation_id: "source-credit-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-04",
          group_id: "source-group",
          refund_method: "hotel_credit"
        },
        open_operation(
          "credit-target",
          [%{room_id: "target-room", nightly_rate_cents: 1000}],
          %{arrival_on: "2027-02-01", departure_on: "2027-02-02"}
        ),
        %{
          operation_id: "apply-source-credit",
          type: "apply_hotel_credit",
          occurred_on: "2026-10-05",
          group_id: "credit-target",
          amount_cents: 200
        },
        %{
          operation_id: "chargeback-payment-a",
          type: "charge_back_payment",
          payment_operation_id: "cash-payment-a",
          expected_revision: 4
        }
      ])

    assert Enum.at(results, 6) == %{
             "operation_id" => "chargeback-payment-a",
             "status" => "applied",
             "payment_operation_id" => "cash-payment-a",
             "group_id" => "source-group",
             "charged_back_cents" => 101,
             "outstanding_deposit_cents" => 0,
             "revision" => 5
           }

    charged_back_ledger =
      conn
      |> get("/api/v1/ledger?on=2026-10-05")
      |> json_response(200)
      |> Map.fetch!("data")

    assert charged_back_ledger["cash_held_cents"] == 0
    assert charged_back_ledger["cash_converted_to_credit_cents"] == 101
    assert charged_back_ledger["cash_charged_back_cents"] == 101
    assert charged_back_ledger["credit_liability_cents"] == 200
    assert charged_back_ledger["credit_shortfall_cents"] == 89

    assert conn
           |> get("/api/v1/payments/cash-payment-a")
           |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "cash-payment-a",
               "original_group_id" => "source-group",
               "recorded_cents" => 101,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 101
             }
           }

    assert Enum.at(
             post_batch(conn, [
               %{
                 operation_id: "restore-shortfall-credit",
                 type: "cancel_group",
                 occurred_on: "2026-10-06",
                 group_id: "credit-target"
               }
             ]),
             0
           )["status"] == "applied"

    final_ledger =
      conn
      |> get("/api/v1/ledger?on=2026-10-06")
      |> json_response(200)
      |> Map.fetch!("data")

    assert final_ledger["credit_liability_cents"] == 111
    assert final_ledger["credit_shortfall_cents"] == 0

    assert conn
           |> get("/api/v1/guests/guest-room-test/credit?on=2026-10-06")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 111
  end

  test "cash reductions compose and chargebacks preserve exact payment statements", %{conn: conn} do
    operations = [
      open_operation("reduction-group", [
        %{room_id: "room-a", nightly_rate_cents: 2000},
        %{room_id: "room-b", nightly_rate_cents: 2000}
      ]),
      %{
        operation_id: "reduction-payment-a",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "reduction-group",
        amount_cents: 600
      },
      %{
        operation_id: "reduction-payment-b",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "reduction-group",
        amount_cents: 200
      },
      %{
        operation_id: "reduce-a-part-one",
        type: "reduce_cash_payment",
        payment_operation_id: "reduction-payment-a",
        amount_cents: 100,
        expected_revision: 3
      },
      %{
        operation_id: "reduce-a-part-two",
        type: "reduce_cash_payment",
        payment_operation_id: "reduction-payment-a",
        amount_cents: 500,
        expected_revision: 4
      },
      %{
        operation_id: "reduce-a-after-exhaustion",
        type: "reduce_cash_payment",
        payment_operation_id: "reduction-payment-a",
        amount_cents: 1
      },
      %{
        operation_id: "reduce-b-too-much",
        type: "reduce_cash_payment",
        payment_operation_id: "reduction-payment-b",
        amount_cents: 201
      },
      %{
        operation_id: "stale-reduction-before-amount-validation",
        type: "reduce_cash_payment",
        payment_operation_id: "reduction-payment-b",
        amount_cents: -1,
        expected_revision: 3
      },
      %{
        operation_id: "chargeback-b",
        type: "charge_back_payment",
        payment_operation_id: "reduction-payment-b",
        expected_revision: 5
      }
    ]

    first_phase = post_batch(conn, Enum.take(operations, 4))
    assert Enum.map(first_phase, & &1["status"]) == ["applied", "applied", "applied", "applied"]

    partially_reduced_group =
      conn
      |> get("/api/v1/groups/reduction-group")
      |> json_response(200)
      |> get_in(["data"])

    assert Enum.map(partially_reduced_group["rooms"], & &1["cash_paid_cents"]) == [400, 300]

    results = post_batch(conn, Enum.drop(operations, 4))

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "rejected",
             "rejected",
             "rejected",
             "applied"
           ]

    assert Enum.at(results, 1)["code"] == "payment_not_reducible"
    assert Enum.at(results, 2)["code"] == "reduction_exceeds_held_cash"
    assert Enum.at(results, 3)["code"] == "stale_revision"
    assert Enum.at(results, 3)["actual_revision"] == 5
    assert Enum.at(results, 4)["charged_back_cents"] == 200
    assert Enum.at(results, 4)["outstanding_deposit_cents"] == 800
    assert post_batch(conn, [Enum.at(operations, 3)]) |> hd() == Enum.at(first_phase, 3)

    assert conn
           |> get("/api/v1/payments/reduction-payment-a")
           |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "reduction-payment-a",
               "original_group_id" => "reduction-group",
               "recorded_cents" => 600,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 600,
               "charged_back_cents" => 0
             }
           }

    assert conn
           |> get("/api/v1/payments/reduction-payment-b")
           |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "reduction-payment-b",
               "original_group_id" => "reduction-group",
               "recorded_cents" => 200,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 200
             }
           }

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_reduced_cents"] == 600
    assert ledger["cash_charged_back_cents"] == 200

    group =
      conn |> get("/api/v1/groups/reduction-group") |> json_response(200) |> get_in(["data"])

    assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]
    assert group["outstanding_deposit_cents"] == 800
  end

  test "chargebacks reclassify historical cash refunds and retention", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("refund-history", [%{room_id: "refund-room", nightly_rate_cents: 500}]),
        %{
          operation_id: "refunded-cash-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "refund-history",
          amount_cents: 100
        },
        %{
          operation_id: "refund-history-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-05",
          group_id: "refund-history"
        },
        open_operation(
          "retained-history",
          [%{room_id: "retained-room", nightly_rate_cents: 500}],
          %{rate_plan: "advance_purchase"}
        ),
        %{
          operation_id: "retained-cash-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "retained-history",
          amount_cents: 100
        },
        %{
          operation_id: "retained-history-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-05",
          group_id: "retained-history"
        },
        %{
          operation_id: "chargeback-refunded-payment",
          type: "charge_back_payment",
          payment_operation_id: "refunded-cash-payment",
          expected_revision: 3
        },
        %{
          operation_id: "chargeback-retained-payment",
          type: "charge_back_payment",
          payment_operation_id: "retained-cash-payment",
          expected_revision: 3
        }
      ])

    assert Enum.at(results, 6)["charged_back_cents"] == 100
    assert Enum.at(results, 7)["charged_back_cents"] == 100

    assert conn
           |> get("/api/v1/payments/refunded-cash-payment")
           |> json_response(200)
           |> get_in(["data", "refunded_cents"]) == 0

    assert conn
           |> get("/api/v1/payments/retained-cash-payment")
           |> json_response(200)
           |> get_in(["data", "retained_cents"]) == 0

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 200
  end
end
