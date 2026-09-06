defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Group, HotelCreditAllocation, HotelCreditLot, Repo}

  test "allocates funding in room order and settles only selected rooms", %{conn: conn} do
    post_batch(conn, [
      open_operation("partial", [
        %{"room_id" => "a", "nightly_rate_cents" => 500},
        %{"room_id" => "b", "nightly_rate_cents" => 500}
      ])
    ])

    post_batch(conn, [cash_payment("payment-one", "partial", 150)])

    assert %{"results" => [payment]} =
             post_batch(conn, [cash_payment("payment-two", "partial", 20)])

    assert payment["outstanding_deposit_cents"] == 30

    assert %{"results" => [cancelled]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-room-b",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-10",
                 "group_id" => "partial",
                 "room_ids" => ["b"],
                 "refund_method" => "hotel_credit"
               }
             ])

    assert cancelled == %{
             "operation_id" => "cancel-room-b",
             "status" => "applied",
             "group_id" => "partial",
             "cancelled_room_ids" => ["b"],
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 77,
             "revision" => 4
           }

    group = json_response(get(conn, "/api/v1/groups/partial"), 200)["data"]
    assert group["status"] == "active"
    assert group["deposit_due_cents"] == 100
    assert group["cash_paid_cents"] == 100
    assert group["outstanding_deposit_cents"] == 0

    assert Enum.map(
             group["rooms"],
             &Map.take(&1, ["room_id", "status", "cash_paid_cents", "credit_paid_cents"])
           ) == [
             %{
               "room_id" => "a",
               "status" => "active",
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "b",
               "status" => "cancelled",
               "cash_paid_cents" => 70,
               "credit_paid_cents" => 0
             }
           ]

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-10"), 200)["data"][
             "available_cents"
           ] == 77
  end

  test "reduces held cash in reverse fill order and reconciles the payment", %{conn: conn} do
    post_batch(conn, [
      open_operation("reduce", [
        %{"room_id" => "a", "nightly_rate_cents" => 500},
        %{"room_id" => "b", "nightly_rate_cents" => 500}
      ])
    ])

    post_batch(conn, [
      cash_payment("reduce-target", "reduce", 150),
      cash_payment("reduce-other", "reduce", 20)
    ])

    assert %{"results" => [reduced]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce-one",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-10",
                 "payment_operation_id" => "reduce-target",
                 "amount_cents" => 30,
                 "expected_revision" => 3
               }
             ])

    assert reduced["amount_cents"] == 30
    assert reduced["outstanding_deposit_cents"] == 60
    assert reduced["revision"] == 4

    assert %{"results" => [reduced_again]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce-two",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-11",
                 "payment_operation_id" => "reduce-target",
                 "amount_cents" => 120,
                 "expected_revision" => 4
               }
             ])

    assert reduced_again["outstanding_deposit_cents"] == 180

    assert json_response(get(conn, "/api/v1/payments/reduce-target"), 200) == %{
             "data" => %{
               "payment_operation_id" => "reduce-target",
               "original_group_id" => "reduce",
               "recorded_cents" => 150,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 150,
               "charged_back_cents" => 0
             }
           }
  end

  test "chargeback reclassifies cash and absorbs a credit clawback on restoration", %{conn: conn} do
    post_batch(conn, [
      open_operation("credit-source", [%{"room_id" => "source", "nightly_rate_cents" => 500}])
    ])

    post_batch(conn, [cash_payment("charge-target", "credit-source", 100)])

    post_batch(conn, [
      %{
        "operation_id" => "source-credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-user", [%{"room_id" => "user", "nightly_rate_cents" => 550}])
    ])

    post_batch(conn, [
      %{
        "operation_id" => "credit-use",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-11",
        "group_id" => "credit-user",
        "amount_cents" => 110
      }
    ])

    assert %{"results" => [chargeback]} =
             post_batch(conn, [
               %{
                 "operation_id" => "charge-source",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-12",
                 "payment_operation_id" => "charge-target"
               }
             ])

    assert chargeback["charged_back_cents"] == 100
    assert chargeback["revision"] == 4

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take([
             "cash_held_cents",
             "cash_converted_to_credit_cents",
             "cash_charged_back_cents",
             "credit_liability_cents",
             "credit_shortfall_cents"
           ]) ==
             %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 100,
               "credit_liability_cents" => 110,
               "credit_shortfall_cents" => 110
             }

    assert %{"results" => [restored]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-credit-user",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-13",
                 "group_id" => "credit-user"
               }
             ])

    assert restored["refunded_cents"] == 0

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["credit_liability_cents", "credit_shortfall_cents"]) ==
             %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}
  end

  test "assigns one credit lot's bonus entitlement in funding order", %{conn: conn} do
    post_batch(conn, [
      open_operation("multi-source", [
        %{"room_id" => "a", "nightly_rate_cents" => 1_000},
        %{"room_id" => "b", "nightly_rate_cents" => 1_000}
      ])
    ])

    post_batch(conn, [
      cash_payment("first-cash", "multi-source", 100),
      cash_payment("second-cash", "multi-source", 100)
    ])

    post_batch(conn, [
      %{
        "operation_id" => "multi-source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "multi-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-consumer", [
        %{"room_id" => "consumer", "nightly_rate_cents" => 1_000}
      ])
    ])

    post_batch(conn, [
      %{
        "operation_id" => "consume-part",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-11",
        "group_id" => "credit-consumer",
        "amount_cents" => 150
      }
    ])

    assert %{"results" => [chargeback]} =
             post_batch(conn, [
               %{
                 "operation_id" => "charge-first",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-12",
                 "payment_operation_id" => "first-cash"
               }
             ])

    assert chargeback["charged_back_cents"] == 100

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-12"), 200)["data"] ==
             %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

    assert json_response(get(conn, "/api/v1/ledger?on=2026-10-12"), 200)["data"]
           |> Map.take(["credit_liability_cents", "credit_shortfall_cents"]) ==
             %{"credit_liability_cents" => 150, "credit_shortfall_cents" => 40}
  end

  test "rejects invalid room selections and preserves durable retry results", %{conn: conn} do
    post_batch(conn, [
      open_operation("invalid-selection", [%{"room_id" => "a", "nightly_rate_cents" => 500}])
    ])

    operation = %{
      "operation_id" => "bad-room-cancel",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-10",
      "group_id" => "invalid-selection",
      "room_ids" => ["missing", "missing"]
    }

    assert %{"results" => [rejected]} = post_batch(conn, [operation])
    assert rejected["code"] == "invalid_rooms"

    assert post_batch(conn, [operation]) == %{"results" => [rejected]}

    assert json_response(get(conn, "/api/v1/groups/invalid-selection"), 200)["data"]["status"] ==
             "active"
  end

  test "backfills legacy funding as a senior block before durable funding", %{conn: conn} do
    post_batch(conn, [
      open_operation("legacy", [
        %{"room_id" => "a", "nightly_rate_cents" => 500},
        %{"room_id" => "b", "nightly_rate_cents" => 500}
      ])
    ])

    post_batch(conn, [cash_payment("recorded-funding", "legacy", 50)])

    lot =
      Repo.insert!(%HotelCreditLot{
        guest_id: "guest-22",
        source_operation_id: "old-credit",
        remaining_cents: 0,
        issued_on: ~D[2026-10-01],
        expires_on: ~D[2027-10-01],
        issued_cents: 0,
        unrecovered_clawback_cents: 0
      })

    Repo.insert!(%HotelCreditAllocation{
      group_id: "legacy",
      credit_lot_id: lot.id,
      amount_cents: 100
    })

    group = Repo.get!(Group, "legacy")

    group
    |> Ecto.Changeset.change(
      deposit_paid_cents: 200,
      cash_paid_cents: 100,
      credit_paid_cents: 100,
      room_accounting_initialized: false
    )
    |> Repo.update!()

    rooms = json_response(get(conn, "/api/v1/groups/legacy"), 200)["data"]["rooms"]

    assert Enum.map(rooms, &Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])) ==
             [
               %{"room_id" => "a", "cash_paid_cents" => 50, "credit_paid_cents" => 50},
               %{"room_id" => "b", "cash_paid_cents" => 50, "credit_paid_cents" => 50}
             ]
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(group_id, rooms) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => rooms
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
