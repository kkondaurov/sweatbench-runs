defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, guest_id \\ "guest-1") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel-#{group_id}",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "#{group_id}-a", "nightly_rate_cents" => 5_000},
        %{"room_id" => "#{group_id}-b", "nightly_rate_cents" => 5_000}
      ]
    }
  end

  defp op(type, id, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2027-01-02"}, attrs)
  end

  defp transfer(id, source, destination, amount, attrs \\ %{}) do
    op(
      "transfer_deposit",
      id,
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        attrs
      )
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "moves mixed funding in reverse allocation order and preserves provenance", %{conn: conn} do
    results =
      submit(conn, [
        open("credit-seed"),
        op("record_cash_payment", "seed-pay", %{
          "group_id" => "credit-seed",
          "amount_cents" => 600
        }),
        op("cancel_group", "seed-credit", %{
          "group_id" => "credit-seed",
          "refund_method" => "hotel_credit"
        }),
        open("source"),
        op("apply_hotel_credit", "source-credit", %{
          "group_id" => "source",
          "amount_cents" => 600
        }),
        op("record_cash_payment", "source-pay", %{
          "group_id" => "source",
          "amount_cents" => 900
        }),
        open("destination"),
        transfer("transfer", "source", "destination", 1_000, %{
          "expected_revision" => 3,
          "destination_expected_revision" => 1
        })
      ])

    assert List.last(results) == %{
             "operation_id" => "transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_000,
             "source_outstanding_deposit_cents" => 1_500,
             "destination_outstanding_deposit_cents" => 1_000,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert Enum.map(group("source")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{0, 500}, {0, 0}]

    assert Enum.map(
             group("destination")["rooms"],
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{900, 100}, {0, 0}]

    assert build_conn() |> get("/api/v1/payments/source-pay") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "source-pay",
               "original_group_id" => "source",
               "recorded_cents" => 900,
               "held_cents" => 900,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 900}],
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }

    ledger = build_conn() |> get("/api/v1/ledger?on=2027-01-02") |> json_response(200)
    assert ledger["data"]["cash_held_cents"] == 900
    assert ledger["data"]["credit_liability_cents"] == 660
  end

  test "validates existence and revisions before transfer rules without mutation", %{conn: conn} do
    [_, _, missing_source, missing_destination, stale_source, stale_destination, invalid] =
      submit(conn, [
        open("source"),
        open("destination", "guest-2"),
        transfer("missing-source", "absent", "also-absent", -1),
        transfer("missing-destination", "source", "absent", -1),
        transfer("stale-source", "source", "destination", -1, %{
          "expected_revision" => 9,
          "destination_expected_revision" => 9
        }),
        transfer("stale-destination", "source", "destination", -1, %{
          "expected_revision" => 1,
          "destination_expected_revision" => 9
        }),
        transfer("invalid", "source", "destination", -1)
      ])

    assert Map.take(missing_source, ["code", "group_id"]) == %{
             "code" => "group_not_found",
             "group_id" => "absent"
           }

    assert Map.take(missing_destination, ["code", "group_id"]) == %{
             "code" => "group_not_found",
             "group_id" => "absent"
           }

    assert Map.take(stale_source, ["code", "group_id", "actual_revision"]) == %{
             "code" => "stale_revision",
             "group_id" => "source",
             "actual_revision" => 1
           }

    assert Map.take(stale_destination, ["code", "group_id", "actual_revision"]) == %{
             "code" => "stale_revision",
             "group_id" => "destination",
             "actual_revision" => 1
           }

    assert invalid["code"] == "invalid_transfer"
    assert group("source")["revision"] == 1
    assert group("destination")["revision"] == 1
  end

  test "replays a durable transfer exactly and does not move funding twice", %{conn: conn} do
    operation = transfer("transfer", "source", "destination", 500)

    [_, _, _, first, replay] =
      submit(conn, [
        open("source"),
        op("record_cash_payment", "pay", %{"group_id" => "source", "amount_cents" => 1_000}),
        open("destination"),
        operation,
        operation
      ])

    assert replay == first
    assert group("source")["cash_paid_cents"] == 500
    assert group("destination")["cash_paid_cents"] == 500
    assert group("source")["revision"] == 3
    assert group("destination")["revision"] == 2
  end

  test "rejects inactive groups and transfer amounts atomically", %{conn: conn} do
    [
      _,
      _,
      _,
      _,
      _,
      invalid_amount,
      exceeds_held,
      exceeds_outstanding,
      _,
      inactive_source,
      inactive_destination
    ] =
      submit(conn, [
        open("source"),
        op("record_cash_payment", "source-pay", %{
          "group_id" => "source",
          "amount_cents" => 1_000
        }),
        open("destination"),
        op("record_cash_payment", "destination-pay", %{
          "group_id" => "destination",
          "amount_cents" => 1_600
        }),
        open("cancelled"),
        transfer("invalid-amount", "source", "destination", 0),
        transfer("exceeds-held", "source", "destination", 1_001),
        transfer("exceeds-outstanding", "source", "destination", 500),
        op("cancel_group", "cancel", %{"group_id" => "cancelled"}),
        transfer("inactive-source", "cancelled", "destination", 1),
        transfer("inactive-destination", "source", "cancelled", 1)
      ])

    assert invalid_amount["code"] == "invalid_amount"
    assert exceeds_held["code"] == "transfer_exceeds_held_funding"
    assert exceeds_outstanding["code"] == "transfer_exceeds_outstanding"

    assert Map.take(inactive_source, ["code", "group_id"]) == %{
             "code" => "group_not_active",
             "group_id" => "cancelled"
           }

    assert Map.take(inactive_destination, ["code", "group_id"]) == %{
             "code" => "group_not_active",
             "group_id" => "cancelled"
           }

    assert group("source")["revision"] == 2
    assert group("destination")["revision"] == 2
  end

  test "reductions follow transferred allocations and revise every changed group once", %{
    conn: conn
  } do
    [_, _, _, _, reduced] =
      submit(conn, [
        open("source"),
        op("record_cash_payment", "pay", %{"group_id" => "source", "amount_cents" => 1_500}),
        open("destination"),
        transfer("transfer", "source", "destination", 900),
        op("reduce_cash_payment", "reduce", %{
          "payment_operation_id" => "pay",
          "amount_cents" => 1_000,
          "expected_revision" => 3
        })
      ])

    assert reduced["revision"] == 4
    assert reduced["outstanding_deposit_cents"] == 1_500
    assert group("source")["revision"] == 4
    assert group("source")["cash_paid_cents"] == 500
    assert group("destination")["revision"] == 3
    assert group("destination")["cash_paid_cents"] == 0

    statement =
      build_conn() |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")

    assert statement["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 500}]
    assert statement["reduced_cents"] == 1_000
  end

  test "a partial reduction does not revise an untouched funding group", %{conn: conn} do
    [_, _, _, _, _, _, reduction] =
      submit(conn, [
        open("source"),
        op("record_cash_payment", "pay", %{"group_id" => "source", "amount_cents" => 1_500}),
        open("older-destination"),
        transfer("older-transfer", "source", "older-destination", 400),
        open("newer-destination"),
        transfer("newer-transfer", "source", "newer-destination", 500),
        op("reduce_cash_payment", "reduce", %{
          "payment_operation_id" => "pay",
          "amount_cents" => 500,
          "expected_revision" => 4
        })
      ])

    assert reduction["revision"] == 5
    assert group("source")["revision"] == 5
    assert group("newer-destination")["revision"] == 3
    assert group("newer-destination")["cash_paid_cents"] == 0
    assert group("older-destination")["revision"] == 2
    assert group("older-destination")["cash_paid_cents"] == 400
  end

  test "transferred hotel credit returns to its original lot on refundable cancellation", %{
    conn: conn
  } do
    submit(conn, [
      open("credit-seed"),
      op("record_cash_payment", "seed-pay", %{
        "group_id" => "credit-seed",
        "amount_cents" => 1_000
      }),
      op("cancel_group", "original-lot", %{
        "group_id" => "credit-seed",
        "refund_method" => "hotel_credit"
      }),
      open("source"),
      op("apply_hotel_credit", "apply", %{"group_id" => "source", "amount_cents" => 600}),
      open("destination"),
      transfer("transfer", "source", "destination", 600),
      op("cancel_group", "cancel-destination", %{"group_id" => "destination"})
    ])

    assert build_conn()
           |> get("/api/v1/guests/guest-1/credit?on=2027-01-02")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-1",
               "available_cents" => 1_100,
               "lots" => [
                 %{
                   "source_operation_id" => "original-lot",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-01-03"
                 }
               ]
             }
           }
  end

  test "transferred cash settles at the destination and chargeback revises both groups", %{
    conn: conn
  } do
    [_, _, _, _, cancellation, chargeback] =
      submit(conn, [
        open("source"),
        op("record_cash_payment", "pay", %{"group_id" => "source", "amount_cents" => 900}),
        open("destination"),
        transfer("transfer", "source", "destination", 900),
        op("cancel_group", "cancel-destination", %{"group_id" => "destination"}),
        op("charge_back_payment", "chargeback", %{
          "payment_operation_id" => "pay",
          "expected_revision" => 3
        })
      ])

    assert cancellation["refunded_cents"] == 900
    assert chargeback["charged_back_cents"] == 900
    assert chargeback["revision"] == 4
    assert group("source")["revision"] == 4
    assert group("destination")["revision"] == 4

    statement =
      build_conn() |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")

    assert statement["held_by_group"] == []
    assert statement["refunded_cents"] == 0
    assert statement["charged_back_cents"] == 900

    ledger = build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 900
  end
end
