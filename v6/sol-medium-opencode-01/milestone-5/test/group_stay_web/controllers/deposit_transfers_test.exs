defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "hotel-1",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 5_000},
          %{"room_id" => "b", "nightly_rate_cents" => 10_000},
          %{"room_id" => "c", "nightly_rate_cents" => 15_000}
        ]
      },
      overrides
    )
  end

  defp pay(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(source, destination, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "transfer-#{source}-#{destination}",
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-03",
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp submit(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{operations: operations})

  defp group(conn, group_id) do
    get(recycle(conn), "/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp statement(conn, payment_id) do
    get(recycle(conn), "/api/v1/payments/#{payment_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "moves mixed funding in reverse allocation order and reports transferred cash", %{
    conn: conn
  } do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "credit-origin",
      "refund_method" => "hotel_credit"
    }

    apply_credit = %{
      "operation_id" => "apply-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-02",
      "group_id" => "source",
      "amount_cents" => 1_000
    }

    move =
      transfer("source", "destination", 1_500, %{
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })

    conn =
      submit(conn, [
        open("credit-origin"),
        pay("credit-origin", "credit-payment", 1_000),
        convert,
        open("source"),
        pay("source", "source-payment", 1_000),
        apply_credit,
        open("destination"),
        move,
        move
      ])

    assert %{"results" => results} = json_response(conn, 200)
    moved = Enum.at(results, 7)
    assert moved == Enum.at(results, 8)
    assert moved["status"] == "applied"
    assert moved["amount_cents"] == 1_500
    assert moved["source_outstanding_deposit_cents"] == 5_500
    assert moved["destination_outstanding_deposit_cents"] == 4_500
    assert moved["source_revision"] == 4
    assert moved["destination_revision"] == 2

    source = group(conn, "source")
    destination = group(conn, "destination")

    assert Enum.map(source["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{500, 0}, {0, 0}, {0, 0}]

    assert Enum.map(destination["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{0, 1_000}, {500, 0}, {0, 0}]

    assert statement(conn, "source-payment")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 500},
             %{"group_id" => "source", "amount_cents" => 500}
           ]

    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2027-01-03") |> json_response(200)
    assert ledger["data"]["cash_held_cents"] == 1_000
    assert ledger["data"]["credit_liability_cents"] == 1_100
  end

  test "reductions follow transferred allocations and revise every changed group", %{conn: conn} do
    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-04",
      "payment_operation_id" => "payment",
      "amount_cents" => 750,
      "expected_revision" => 3
    }

    conn =
      submit(conn, [
        open("source"),
        pay("source", "payment", 1_000),
        open("destination"),
        transfer("source", "destination", 500),
        reduction
      ])

    reduced = get_in(json_response(conn, 200), ["results", Access.at(4)])
    assert reduced["revision"] == 4
    assert reduced["outstanding_deposit_cents"] == 5_750
    assert group(conn, "destination")["revision"] == 3
    assert group(conn, "destination")["outstanding_deposit_cents"] == 6_000

    payment = statement(conn, "payment")
    assert payment["held_cents"] == 250
    assert payment["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 250}]
  end

  test "chargebacks reverse transferred settlement on every affected group", %{conn: conn} do
    cancel_destination = %{
      "operation_id" => "cancel-destination",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-04",
      "group_id" => "destination"
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => "payment",
      "expected_revision" => 3
    }

    conn =
      submit(conn, [
        open("source"),
        pay("source", "payment", 1_000),
        open("destination"),
        transfer("source", "destination", 500),
        cancel_destination,
        chargeback
      ])

    result = get_in(json_response(conn, 200), ["results", Access.at(5)])
    assert result["charged_back_cents"] == 1_000
    assert result["revision"] == 4
    assert group(conn, "destination")["revision"] == 4

    ledger = get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200)
    assert ledger["data"]["cash_held_cents"] == 0
    assert ledger["data"]["cash_refunded_cents"] == 0
    assert ledger["data"]["cash_charged_back_cents"] == 1_000
    assert statement(conn, "payment")["held_by_group"] == []
  end

  test "destination settlement restores transferred credit and converts transferred cash", %{
    conn: conn
  } do
    convert_origin = %{
      "operation_id" => "convert-origin",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "credit-origin",
      "refund_method" => "hotel_credit"
    }

    apply_credit = %{
      "operation_id" => "apply-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-02",
      "group_id" => "source",
      "amount_cents" => 500
    }

    convert_destination = %{
      "operation_id" => "convert-destination",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-04",
      "group_id" => "destination",
      "refund_method" => "hotel_credit"
    }

    chargeback = %{
      "operation_id" => "chargeback-transferred",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => "source-payment",
      "expected_revision" => 4
    }

    conn =
      submit(conn, [
        open("credit-origin"),
        pay("credit-origin", "credit-payment", 1_000),
        convert_origin,
        open("source"),
        pay("source", "source-payment", 500),
        apply_credit,
        open("destination"),
        transfer("source", "destination", 1_000),
        convert_destination,
        chargeback
      ])

    assert get_in(json_response(conn, 200), ["results", Access.at(8)])[
             "credit_issued_cents"
           ] == 550

    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "source")["revision"] == 5

    payment = statement(conn, "source-payment")
    assert payment["converted_to_credit_cents"] == 0
    assert payment["charged_back_cents"] == 500
    assert payment["held_by_group"] == []

    credit =
      get(recycle(conn), "/api/v1/guests/guest-1/credit?on=2027-01-05")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 1_100
    assert Enum.map(credit["lots"], & &1["source_operation_id"]) == ["convert-origin"]

    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2027-01-05") |> json_response(200)
    assert ledger["data"]["cash_converted_to_credit_cents"] == 1_000
    assert ledger["data"]["cash_charged_back_cents"] == 500
    assert ledger["data"]["credit_liability_cents"] == 1_100
  end

  test "applies transfer validation in existence, revision, and domain order", %{conn: conn} do
    missing_source = transfer("missing", "destination", 1)
    missing_destination = transfer("source", "missing", 1)

    stale_source =
      transfer("source", "destination", -1, %{
        "operation_id" => "stale-source",
        "expected_revision" => 99,
        "destination_expected_revision" => 99
      })

    stale_destination =
      transfer("source", "destination", -1, %{
        "operation_id" => "stale-destination",
        "expected_revision" => 1,
        "destination_expected_revision" => 99
      })

    conn =
      submit(conn, [
        missing_source,
        open("source"),
        missing_destination,
        open("destination"),
        stale_source,
        stale_destination,
        transfer("source", "source", 1, %{"operation_id" => "same"}),
        transfer("source", "destination", 0, %{"operation_id" => "zero"}),
        transfer("source", "destination", 1, %{"operation_id" => "no-funding"}),
        open("other-guest", %{"guest_id" => "guest-2"}),
        transfer("source", "other-guest", 1, %{"operation_id" => "other-guest"})
      ])

    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.at(results, 0)["code"] == "group_not_found"
    assert Enum.at(results, 0)["group_id"] == "missing"
    assert Enum.at(results, 2)["code"] == "group_not_found"
    assert Enum.at(results, 2)["group_id"] == "missing"
    assert Enum.at(results, 4)["code"] == "stale_revision"
    assert Enum.at(results, 4)["group_id"] == "source"
    assert Enum.at(results, 5)["code"] == "stale_revision"
    assert Enum.at(results, 5)["group_id"] == "destination"
    assert Enum.at(results, 6)["code"] == "invalid_transfer"
    assert Enum.at(results, 7)["code"] == "invalid_amount"
    assert Enum.at(results, 8)["code"] == "transfer_exceeds_held_funding"
    assert Enum.at(results, 10)["code"] == "invalid_transfer"
    assert group(conn, "source")["revision"] == 1
    assert group(conn, "destination")["revision"] == 1
  end
end
