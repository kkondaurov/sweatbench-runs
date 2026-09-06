defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Bookings.{CreditAllocation, CreditLot, Room, RoomFundingAllocation}
  alias GroupStay.Repo

  test "moves mixed funding in reverse allocation order, preserves provenance, and retries exactly",
       %{conn: conn} do
    setup_operations = [
      open("credit-seed", "guest", [{"seed", 5_000}]),
      operation("seed-payment", "record_cash_payment", %{
        "group_id" => "credit-seed",
        "amount_cents" => 1_000
      }),
      operation("seed-cancel", "cancel_group", %{
        "group_id" => "credit-seed",
        "refund_method" => "hotel_credit"
      }),
      open("source", "guest", [{"s1", 5_000}, {"s2", 5_000}, {"s3", 5_000}]),
      operation("pay-a", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      operation("credit-a", "apply_hotel_credit", %{
        "group_id" => "source",
        "amount_cents" => 800
      }),
      operation("pay-b", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 700
      }),
      open("destination", "guest", [{"d1", 3_000}, {"d2", 3_000}])
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => setup_operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    ledger_before = get_json("/api/v1/ledger")["data"]

    transfer =
      operation("move-mixed", "transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 900,
        "expected_revision" => 4,
        "destination_expected_revision" => 1
      })

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [transfer, transfer]
      })

    assert %{"results" => [moved, retried]} = json_response(conn, 200)
    assert retried == moved

    assert moved == %{
             "operation_id" => "move-mixed",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 900,
             "source_outstanding_deposit_cents" => 1_400,
             "destination_outstanding_deposit_cents" => 300,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert get_json("/api/v1/operations/move-mixed") == %{"data" => moved}
    assert get_json("/api/v1/ledger")["data"] == ledger_before

    source = get_json("/api/v1/groups/source")["data"]
    destination = get_json("/api/v1/groups/destination")["data"]

    assert {source["cash_paid_cents"], source["credit_paid_cents"], source["revision"]} ==
             {1_000, 600, 5}

    assert {destination["cash_paid_cents"], destination["credit_paid_cents"],
            destination["revision"]} == {700, 200, 2}

    assert Enum.map(destination["rooms"], fn room ->
             {room["room_id"], room["cash_paid_cents"], room["credit_paid_cents"]}
           end) == [{"d1", 600, 0}, {"d2", 100, 200}]

    destination_allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == "destination",
          order_by: allocation.id,
          select: {
            room.room_id,
            allocation.funding_type,
            allocation.payment_operation_id,
            allocation.credit_lot_id,
            allocation.amount_cents
          }
      )

    assert [
             {"d1", "cash", "pay-b", nil, 500},
             {"d1", "cash", "pay-b", nil, 100},
             {"d2", "cash", "pay-b", nil, 100},
             {"d2", "credit", nil, credit_lot_id, 200}
           ] = destination_allocations

    assert %CreditLot{source_operation_id: "seed-cancel"} = Repo.get!(CreditLot, credit_lot_id)

    assert Repo.get_by!(CreditAllocation, credit_lot_id: credit_lot_id, group_id: "source").amount_cents ==
             600

    assert Repo.get_by!(CreditAllocation,
             credit_lot_id: credit_lot_id,
             group_id: "destination"
           ).amount_cents == 200

    assert get_json("/api/v1/payments/pay-b")["data"]["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 700}
           ]

    refute Map.has_key?(get_json("/api/v1/payments/pay-a")["data"], "held_by_group")

    assert get_json("/api/v1/operations/pay-b")["data"] == %{
             "operation_id" => "pay-b",
             "status" => "applied",
             "group_id" => "source",
             "amount_cents" => 700,
             "outstanding_deposit_cents" => 500,
             "revision" => 4
           }
  end

  test "applies transfer existence and revision precedence and rejects every domain rule", %{
    conn: conn
  } do
    setup_operations = [
      open("source", "guest", [{"s", 5_000}]),
      operation("source-payment", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 500
      }),
      open("destination", "guest", [{"d", 5_000}]),
      open("other-guest", "stranger", [{"o", 5_000}]),
      open("inactive-source", "guest", [{"is", 5_000}]),
      operation("cancel-inactive-source", "cancel_group", %{"group_id" => "inactive-source"}),
      open("inactive-destination", "guest", [{"id", 5_000}]),
      operation("cancel-inactive-destination", "cancel_group", %{
        "group_id" => "inactive-destination"
      }),
      open("tight-destination", "guest", [{"td", 5_000}]),
      operation("tight-payment", "record_cash_payment", %{
        "group_id" => "tight-destination",
        "amount_cents" => 800
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => setup_operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    attempts = [
      transfer("missing-source", "missing", "also-missing", 1),
      transfer("missing-destination", "source", "missing", 1),
      transfer("stale-source", "source", "destination", 0, %{
        "expected_revision" => 1,
        "destination_expected_revision" => 99
      }),
      transfer("stale-destination", "source", "destination", 0, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 99
      }),
      transfer("same-group", "source", "source", 1),
      transfer("different-guests", "source", "other-guest", 1),
      transfer("inactive-source", "inactive-source", "destination", 1),
      transfer("inactive-destination", "source", "inactive-destination", 1),
      transfer("zero", "source", "destination", 0),
      transfer("too-much-funding", "source", "destination", 501),
      transfer("too-little-room", "source", "tight-destination", 500)
    ]

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => attempts})
    assert %{"results" => rejected} = json_response(conn, 200)

    assert Enum.map(rejected, & &1["code"]) == [
             "group_not_found",
             "group_not_found",
             "stale_revision",
             "stale_revision",
             "invalid_transfer",
             "invalid_transfer",
             "group_not_active",
             "group_not_active",
             "invalid_amount",
             "transfer_exceeds_held_funding",
             "transfer_exceeds_outstanding"
           ]

    assert Enum.at(rejected, 0)["group_id"] == "missing"
    assert Enum.at(rejected, 1)["group_id"] == "missing"

    assert Map.take(Enum.at(rejected, 2), ["group_id", "expected_revision", "actual_revision"]) ==
             %{"group_id" => "source", "expected_revision" => 1, "actual_revision" => 2}

    assert Map.take(Enum.at(rejected, 3), ["group_id", "expected_revision", "actual_revision"]) ==
             %{"group_id" => "destination", "expected_revision" => 99, "actual_revision" => 1}

    assert Enum.at(rejected, 6)["group_id"] == "inactive-source"
    assert Enum.at(rejected, 7)["group_id"] == "inactive-destination"

    assert get_json("/api/v1/groups/source")["data"]["revision"] == 2
    assert get_json("/api/v1/groups/destination")["data"]["revision"] == 1
    assert get_json("/api/v1/groups/source")["data"]["cash_paid_cents"] == 500
  end

  test "reductions follow transferred allocations and increment every changed group once", %{
    conn: conn
  } do
    operations = [
      open("original", "guest", [{"o1", 5_000}, {"o2", 5_000}]),
      operation("payment", "record_cash_payment", %{
        "group_id" => "original",
        "amount_cents" => 1_500
      }),
      open("holder", "guest", [{"h1", 5_000}]),
      transfer("move", "original", "holder", 1_000, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      operation("reduction", "reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 1_200,
        "expected_revision" => 3
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, _, transfer_result, reduction]} = json_response(conn, 200)
    assert transfer_result["status"] == "applied"

    assert reduction == %{
             "operation_id" => "reduction",
             "status" => "applied",
             "payment_operation_id" => "payment",
             "group_id" => "original",
             "amount_cents" => 1_200,
             "outstanding_deposit_cents" => 1_700,
             "revision" => 4
           }

    original = get_json("/api/v1/groups/original")["data"]
    holder = get_json("/api/v1/groups/holder")["data"]
    assert {original["cash_paid_cents"], original["revision"]} == {300, 4}
    assert {holder["cash_paid_cents"], holder["revision"]} == {0, 3}

    payment = get_json("/api/v1/payments/payment")["data"]
    assert payment["held_cents"] == 300
    assert payment["reduced_cents"] == 1_200

    assert payment["held_by_group"] == [
             %{"group_id" => "original", "amount_cents" => 300}
           ]

    ledger = get_json("/api/v1/ledger")["data"]
    assert ledger["cash_held_cents"] == 300
    assert ledger["cash_reduced_cents"] == 1_200
  end

  test "transferred cash settles at the destination and chargeback reclassifies that group", %{
    conn: conn
  } do
    operations = [
      open("source", "guest", [{"s", 5_000}]),
      operation("payment", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      open("nonref-destination", "guest", [{"d", 1_000}], "advance_purchase"),
      transfer("move", "source", "nonref-destination", 1_000),
      operation("cancel-destination", "cancel_group", %{"group_id" => "nonref-destination"}),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "payment",
        "expected_revision" => 3
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, _, _, cancellation, chargeback]} = json_response(conn, 200)
    assert cancellation["retained_cents"] == 1_000
    assert cancellation["refunded_cents"] == 0

    assert chargeback["charged_back_cents"] == 1_000
    assert chargeback["group_id"] == "source"
    assert chargeback["revision"] == 4

    assert get_json("/api/v1/groups/source")["data"]["revision"] == 4
    assert get_json("/api/v1/groups/nonref-destination")["data"]["revision"] == 4

    payment = get_json("/api/v1/payments/payment")["data"]
    assert payment["held_cents"] == 0
    assert payment["retained_cents"] == 0
    assert payment["charged_back_cents"] == 1_000
    assert payment["held_by_group"] == []

    ledger = get_json("/api/v1/ledger")["data"]
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 1_000
  end

  test "transferred hotel credit returns to its original lot without a second bonus", %{
    conn: conn
  } do
    operations = [
      open("seed", "guest", [{"seed-room", 5_000}]),
      operation("seed-payment", "record_cash_payment", %{
        "group_id" => "seed",
        "amount_cents" => 1_000
      }),
      operation("original-credit", "cancel_group", %{
        "group_id" => "seed",
        "refund_method" => "hotel_credit"
      }),
      open("source", "guest", [{"source-room", 5_000}]),
      operation("use-credit", "apply_hotel_credit", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      open("destination", "guest", [{"destination-room", 5_000}]),
      transfer("move-credit", "source", "destination", 600),
      operation("cancel-destination", "cancel_group", %{"group_id" => "destination"})
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert List.last(results)["credit_issued_cents"] == 0
    assert List.last(results)["refunded_cents"] == 0

    credit = get_json("/api/v1/guests/guest/credit?on=2026-10-03")["data"]
    assert credit["available_cents"] == 700

    assert credit["lots"] == [
             %{
               "source_operation_id" => "original-credit",
               "remaining_cents" => 700,
               "expires_on" => "2027-10-03"
             }
           ]

    source = get_json("/api/v1/groups/source")["data"]
    assert source["credit_paid_cents"] == 400
    assert source["revision"] == 3

    ledger = get_json("/api/v1/ledger?on=2026-10-03")["data"]
    assert ledger["credit_liability_cents"] == 1_100
    assert ledger["cash_converted_to_credit_cents"] == 1_000
  end

  test "drains multiple allocations on one source room without using stale room totals", %{
    conn: conn
  } do
    operations = [
      open("source", "guest", [{"only-source-room", 5_000}]),
      operation("first-payment", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 400
      }),
      operation("second-payment", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 600
      }),
      open("destination", "guest", [{"only-destination-room", 5_000}]),
      transfer("move-all", "source", "destination", 1_000)
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    source = get_json("/api/v1/groups/source")["data"]
    destination = get_json("/api/v1/groups/destination")["data"]
    assert source["cash_paid_cents"] == 0
    assert hd(source["rooms"])["cash_paid_cents"] == 0
    assert destination["cash_paid_cents"] == 1_000
    assert hd(destination["rooms"])["cash_paid_cents"] == 1_000
    assert get_json("/api/v1/ledger")["data"]["cash_held_cents"] == 1_000
  end

  test "chargeback revokes credit created from cash settled after a transfer", %{conn: conn} do
    operations = [
      open("source", "guest", [{"source-room", 5_000}]),
      operation("payment", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      open("destination", "guest", [{"destination-room", 5_000}]),
      transfer("move", "source", "destination", 1_000),
      operation("convert-at-destination", "cancel_group", %{
        "group_id" => "destination",
        "refund_method" => "hotel_credit"
      }),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "payment",
        "expected_revision" => 3
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, _, _, conversion, chargeback]} = json_response(conn, 200)
    assert conversion["credit_issued_cents"] == 1_100
    assert chargeback["charged_back_cents"] == 1_000
    assert chargeback["revision"] == 4

    assert get_json("/api/v1/groups/source")["data"]["revision"] == 4
    assert get_json("/api/v1/groups/destination")["data"]["revision"] == 4

    credit = get_json("/api/v1/guests/guest/credit?on=2026-10-03")["data"]
    assert credit["available_cents"] == 0
    assert credit["lots"] == []

    ledger = get_json("/api/v1/ledger?on=2026-10-03")["data"]
    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 1_000
    assert ledger["credit_liability_cents"] == 0
    assert ledger["credit_shortfall_cents"] == 0
  end

  defp get_json(path) do
    build_conn()
    |> get(path)
    |> json_response(200)
  end

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents, extra \\ %{}) do
    operation(operation_id, "transfer_deposit", %{
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    })
    |> Map.merge(extra)
  end

  defp open(group_id, guest_id, rooms, rate_plan \\ "flexible") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => rate_plan,
      "rooms" =>
        Enum.map(rooms, fn {room_id, nightly_rate_cents} ->
          %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}
        end)
    }
  end

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{"operation_id" => operation_id, "type" => type, "occurred_on" => "2026-10-03"},
      fields
    )
  end
end
