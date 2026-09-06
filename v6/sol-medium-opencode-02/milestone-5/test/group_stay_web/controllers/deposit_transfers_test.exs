defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, operation_id, guest_id, rates, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "hotel-#{group_id}",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "advance_purchase",
        "rooms" =>
          rates
          |> Enum.with_index(1)
          |> Enum.map(fn {rate, index} ->
            %{"room_id" => "room-#{index}", "nightly_rate_cents" => rate}
          end)
      },
      overrides
    )
  end

  defp operation(type, id, attrs) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "occurred_on" => "2026-10-02"},
      attrs
    )
  end

  defp transfer(id, source, destination, amount, attrs \\ %{}) do
    operation(
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

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment(conn, operation_id) do
    conn
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "moves newest funding first, fills destination rooms in order, and replays exactly", %{
    conn: conn
  } do
    assert Enum.all?(
             submit(conn, [
               open("source", "open-source", "guest", [1_000, 1_000]),
               open("destination", "open-destination", "guest", [600, 1_400]),
               operation("record_cash_payment", "pay-1", %{
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }),
               operation("record_cash_payment", "pay-2", %{
                 "group_id" => "source",
                 "amount_cents" => 800
               })
             ]),
             &(&1["status"] == "applied")
           )

    refute Map.has_key?(payment(conn, "pay-1"), "held_by_group")

    transfer =
      transfer("transfer", "source", "destination", 1_200, %{
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })

    assert [result] = submit(conn, [transfer])

    assert result == %{
             "operation_id" => "transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_200,
             "source_outstanding_deposit_cents" => 1_400,
             "destination_outstanding_deposit_cents" => 800,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert submit(conn, [transfer]) == [result]

    assert Enum.map(group(conn, "source")["rooms"], & &1["cash_paid_cents"]) == [600, 0]
    assert Enum.map(group(conn, "destination")["rooms"], & &1["cash_paid_cents"]) == [600, 600]

    assert payment(conn, "pay-1")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 400},
             %{"group_id" => "source", "amount_cents" => 600}
           ]

    assert payment(conn, "pay-2")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 800}
           ]

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 1_800
    assert ledger["cash_reduced_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 0
  end

  test "reduces transferred cash in global reverse allocation order and revises both groups", %{
    conn: conn
  } do
    assert Enum.all?(
             submit(conn, [
               open("source", "open-source", "guest", [1_000, 1_000]),
               open("destination", "open-destination", "guest", [600, 1_400]),
               operation("record_cash_payment", "pay", %{
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }),
               transfer("transfer", "source", "destination", 400)
             ]),
             &(&1["status"] == "applied")
           )

    assert [reduced] =
             submit(conn, [
               operation("reduce_cash_payment", "reduce", %{
                 "payment_operation_id" => "pay",
                 "amount_cents" => 700,
                 "expected_revision" => 3
               })
             ])

    assert reduced["group_id"] == "source"
    assert reduced["revision"] == 4
    assert reduced["outstanding_deposit_cents"] == 1_700
    assert group(conn, "destination")["revision"] == 3
    assert group(conn, "destination")["cash_paid_cents"] == 0

    assert payment(conn, "pay")["held_by_group"] == [
             %{"group_id" => "source", "amount_cents" => 300}
           ]

    source = GroupStay.Repo.get_by!(GroupStay.Group, group_id: "source")
    destination = GroupStay.Repo.get_by!(GroupStay.Group, group_id: "destination")
    assert source.cash_reduced_cents == 300
    assert destination.cash_reduced_cents == 400
  end

  test "transferred cash settles under the destination policy and chargeback revises both groups",
       %{
         conn: conn
       } do
    destination =
      open("destination", "open-destination", "guest", [1_000], %{
        "rate_plan" => "flexible"
      })

    assert Enum.all?(
             submit(conn, [
               open("source", "open-source", "guest", [1_000]),
               destination,
               operation("record_cash_payment", "pay", %{
                 "group_id" => "source",
                 "amount_cents" => 100
               }),
               transfer("transfer", "source", "destination", 100),
               operation("cancel_group", "cancel-destination", %{
                 "group_id" => "destination",
                 "occurred_on" => "2026-12-01"
               })
             ]),
             &(&1["status"] == "applied")
           )

    assert payment(conn, "pay")["refunded_cents"] == 100

    assert [charged_back] =
             submit(conn, [
               operation("charge_back_payment", "chargeback", %{
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               })
             ])

    assert charged_back["charged_back_cents"] == 100
    assert charged_back["revision"] == 4
    assert group(conn, "destination")["revision"] == 4
    assert payment(conn, "pay")["held_by_group"] == []
    assert payment(conn, "pay")["refunded_cents"] == 0

    source = GroupStay.Repo.get_by!(GroupStay.Group, group_id: "source")
    destination = GroupStay.Repo.get_by!(GroupStay.Group, group_id: "destination")
    assert source.cash_charged_back_cents == 0
    assert destination.cash_charged_back_cents == 100

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 100
  end

  test "transfers applied credit with its original lot and restores it without another bonus", %{
    conn: conn
  } do
    flexible = %{"rate_plan" => "flexible"}

    assert Enum.all?(
             submit(conn, [
               open("issuer", "open-issuer", "guest", [1_000], flexible),
               operation("record_cash_payment", "issuer-pay", %{
                 "group_id" => "issuer",
                 "amount_cents" => 100
               }),
               operation("cancel_group", "credit-lot", %{
                 "group_id" => "issuer",
                 "occurred_on" => "2026-12-01",
                 "refund_method" => "hotel_credit"
               }),
               open("carrier", "open-carrier", "guest", [1_000]),
               open("recipient", "open-recipient", "guest", [500, 500], flexible),
               operation("record_cash_payment", "carrier-pay", %{
                 "group_id" => "carrier",
                 "amount_cents" => 200
               }),
               operation("apply_hotel_credit", "apply-credit", %{
                 "group_id" => "carrier",
                 "amount_cents" => 110,
                 "occurred_on" => "2026-12-02"
               }),
               transfer("credit-transfer", "carrier", "recipient", 150)
             ]),
             &(&1["status"] == "applied")
           )

    assert group(conn, "carrier")["credit_paid_cents"] == 0
    assert group(conn, "carrier")["cash_paid_cents"] == 160

    recipient = group(conn, "recipient")
    assert recipient["credit_paid_cents"] == 110
    assert recipient["cash_paid_cents"] == 40

    assert Enum.map(recipient["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {0, 100},
             {40, 10}
           ]

    ledger =
      conn |> get("/api/v1/ledger?on=2026-12-02") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 110

    assert [cancelled] =
             submit(conn, [
               operation("cancel_group", "cancel-recipient", %{
                 "group_id" => "recipient",
                 "occurred_on" => "2026-12-03"
               })
             ])

    assert cancelled["credit_issued_cents"] == 0
    assert cancelled["refunded_cents"] == 40

    credit =
      conn
      |> get("/api/v1/guests/guest/credit?on=2026-12-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 110
    assert [%{"source_operation_id" => "credit-lot", "remaining_cents" => 110}] = credit["lots"]
  end

  test "uses lookup and revision precedence before transfer validation and returns stable errors",
       %{
         conn: conn
       } do
    assert Enum.all?(
             submit(conn, [
               open("source", "open-source", "guest-a", [1_000]),
               open("destination", "open-destination", "guest-b", [100]),
               open("inactive", "open-inactive", "guest-a", [100]),
               operation("record_cash_payment", "pay", %{
                 "group_id" => "source",
                 "amount_cents" => 500
               }),
               operation("cancel_group", "cancel-inactive", %{"group_id" => "inactive"})
             ]),
             &(&1["status"] == "applied")
           )

    operations = [
      transfer("missing-source", "missing", "also-missing", 1),
      transfer("missing-destination", "source", "missing", 1),
      transfer("stale-source", "source", "destination", 1, %{
        "expected_revision" => 1,
        "destination_expected_revision" => 0
      }),
      transfer("stale-destination", "source", "destination", 1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 0
      }),
      transfer("different-guests", "source", "destination", 1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      transfer("inactive-destination", "source", "inactive", 1),
      transfer("invalid-amount", "source", "inactive", 0),
      transfer("too-much-funding", "source", "inactive", 501),
      transfer("too-much-outstanding", "source", "inactive", 101)
    ]

    results = submit(conn, operations)

    assert Enum.map(results, & &1["code"]) == [
             "group_not_found",
             "group_not_found",
             "stale_revision",
             "stale_revision",
             "invalid_transfer",
             "group_not_active",
             "group_not_active",
             "group_not_active",
             "group_not_active"
           ]

    assert Enum.at(results, 0)["group_id"] == "missing"
    assert Enum.at(results, 1)["group_id"] == "missing"
    assert Enum.at(results, 2)["group_id"] == "source"
    assert Enum.at(results, 3)["group_id"] == "destination"
    assert Enum.at(results, 5)["group_id"] == "inactive"
    assert group(conn, "source")["revision"] == 2
    assert group(conn, "destination")["revision"] == 1
  end

  test "validates amount and source and destination capacity in order", %{conn: conn} do
    assert Enum.all?(
             submit(conn, [
               open("source", "open-source", "guest", [1_000]),
               open("destination", "open-destination", "guest", [100]),
               operation("record_cash_payment", "pay", %{
                 "group_id" => "source",
                 "amount_cents" => 500
               })
             ]),
             &(&1["status"] == "applied")
           )

    results =
      submit(conn, [
        transfer("zero", "source", "destination", 0),
        transfer("too-much-funding", "source", "destination", 501),
        transfer("too-much-outstanding", "source", "destination", 101)
      ])

    assert Enum.map(results, & &1["code"]) == [
             "invalid_amount",
             "transfer_exceeds_held_funding",
             "transfer_exceeds_outstanding"
           ]

    assert group(conn, "source")["revision"] == 2
    assert group(conn, "destination")["revision"] == 1
  end
end
