defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates availability and durably starts from the exact batch position", %{conn: conn} do
    assert conn |> get("/api/v1/finance/daily-report") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert conn |> get("/api/v1/finance/daily-report?date=nope") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert Enum.map(
             post_batch(conn, [
               start("bad-start", "not-a-date"),
               Map.delete(start("missing", "x"), "starts_on")
             ]),
             & &1["code"]
           ) == ["invalid_reporting_date", "invalid_reporting_date"]

    operations = [
      open("group", "guest", "z-property", "2026-12-10", "flexible", 500),
      cash("before", "group", 60, "2026-10-10"),
      start("start", "2026-10-01"),
      cash("after", "group", 40, "2026-09-01")
    ]

    results = post_batch(conn, operations)

    assert Enum.at(results, 2) == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-10-01"
           }

    report = report("2026-10-01")

    assert report == %{
             "date" => "2026-10-01",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "z-property",
                 "opening_held_cents" => 60,
                 "movements" => cash_movements(%{"received_cents" => 40}),
                 "closing_held_cents" => 100
               }
             ],
             "credit" => credit(0, %{}, 0)
           }

    assert report("2026-09-30") == :not_available
    assert post_batch(build_conn(), [start("start", "2026-10-01")]) |> hd() == Enum.at(results, 2)

    assert post_batch(build_conn(), [start("another-start", "2026-10-02")]) |> hd() == %{
             "operation_id" => "another-start",
             "status" => "rejected",
             "code" => "reporting_already_started"
           }
  end

  test "classifies cash receipts, same-property transfers, refunds, and chargebacks", %{
    conn: conn
  } do
    post_batch(conn, [
      start("start", "2026-10-01"),
      open("source", "guest", "ams-canal", "2026-12-10", "flexible", 500),
      open("destination", "guest", "ams-canal", "2026-12-10", "flexible", 500),
      cash("payment", "source", 100, "2026-10-02"),
      transfer("move", "source", "destination", 40, "2026-10-03"),
      cancel("refund", "destination", "2026-10-04", "cash"),
      chargeback("chargeback", "payment", "2026-10-05")
    ])

    assert cash_entry("2026-10-02") ==
             entry("ams-canal", 0, %{"received_cents" => 100}, 100)

    assert cash_entry("2026-10-03") ==
             entry(
               "ams-canal",
               100,
               %{"transferred_in_cents" => 40, "transferred_out_cents" => 40},
               100
             )

    assert cash_entry("2026-10-04") ==
             entry("ams-canal", 100, %{"refunded_cents" => 40}, 60)

    assert cash_entry("2026-10-05") ==
             entry(
               "ams-canal",
               60,
               %{"refunded_cents" => -40, "charged_back_cents" => 100},
               0
             )

    assert report("2026-10-05") == report("2026-10-05")
  end

  test "reports credit issuance, revocation, absorption, and quiet-day expiry", %{conn: conn} do
    post_batch(conn, [
      open("seed", "guest", "ams-canal", "2027-12-31", "flexible", 500),
      cash("seed-payment", "seed", 100, "2026-10-01"),
      cancel("issue", "seed", "2026-10-02", "hotel_credit"),
      start("start", "2026-10-03"),
      open("funded", "guest", "ams-canal", "2027-12-31", "flexible", 500),
      apply_credit("apply", "funded", 100, "2026-10-04"),
      chargeback("clawback", "seed-payment", "2026-10-05"),
      cancel("absorb", "funded", "2026-10-06", "cash")
    ])

    assert report("2026-10-03")["credit"] == credit(110, %{}, 110)
    assert report("2026-10-04")["credit"] == credit(110, %{}, 110)

    assert report("2026-10-05")["credit"] ==
             credit(110, %{"revoked_cents" => 10}, 100)

    assert report("2026-10-06")["credit"] ==
             credit(100, %{"absorbed_cents" => 100}, 0)

    post_batch(build_conn(), [
      open("expiring", "other", "berlin", "2027-12-31", "flexible", 500),
      cash("expiring-payment", "expiring", 100, "2026-10-07"),
      cancel("expiring-lot", "expiring", "2026-10-08", "hotel_credit")
    ])

    expiry = report("2027-10-09")
    assert expiry["cash"] == []
    assert expiry["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert report("2027-10-09") == expiry
  end

  test "reports reductions, retention, conversion, and non-refundable credit consumption", %{
    conn: conn
  } do
    post_batch(conn, [
      start("start", "2026-10-01"),
      open("reduced", "guest", "ams-canal", "2026-10-10", "flexible", 500),
      cash("reducible", "reduced", 100, "2026-10-01"),
      reduce("reduce", "reducible", 30, "2026-10-02"),
      cancel("retain", "reduced", "2026-10-03", "cash"),
      open("issuer", "guest", "berlin", "2027-12-31", "flexible", 500),
      cash("convertible", "issuer", 100, "2026-10-03"),
      cancel("convert", "issuer", "2026-10-04", "hotel_credit"),
      open("advance", "guest", "berlin", "2027-12-31", "advance_purchase", 100),
      apply_credit("spend", "advance", 100, "2026-10-05"),
      cancel("consume", "advance", "2026-10-06", "cash")
    ])

    assert cash_entry("2026-10-02")["movements"] == cash_movements(%{"reduced_cents" => 30})
    assert cash_entry("2026-10-03")["movements"]["retained_cents"] == 70

    conversion = report("2026-10-04")
    assert List.last(conversion["cash"])["movements"]["converted_to_credit_cents"] == 100
    assert conversion["credit"] == credit(0, %{"issued_cents" => 110}, 110)
    assert report("2026-10-06")["credit"] == credit(110, %{"consumed_cents" => 100}, 10)
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    response = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")

    case response.status do
      200 -> response |> json_response(200) |> Map.fetch!("data")
      404 -> :not_available
    end
  end

  defp cash_entry(date), do: report(date)["cash"] |> List.first()

  defp entry(property, opening, movements, closing) do
    %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => cash_movements(movements),
      "closing_held_cents" => closing
    }
  end

  defp cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit(opening, overrides, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" =>
        Map.merge(
          %{
            "issued_cents" => 0,
            "expired_cents" => 0,
            "consumed_cents" => 0,
            "revoked_cents" => 0,
            "absorbed_cents" => 0
          },
          overrides
        ),
      "closing_liability_cents" => closing
    }
  end

  defp start(id, starts_on),
    do: %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => starts_on}

  defp open(id, guest, property, arrival, rate_plan, nightly_rate) do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => id,
      "guest_id" => guest,
      "property_id" => property,
      "arrival_on" => arrival,
      "departure_on" => arrival |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601(),
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp cash(id, group, amount, on),
    do: operation(id, "record_cash_payment", group, on, %{"amount_cents" => amount})

  defp apply_credit(id, group, amount, on),
    do: operation(id, "apply_hotel_credit", group, on, %{"amount_cents" => amount})

  defp cancel(id, group, on, method),
    do: operation(id, "cancel_group", group, on, %{"refund_method" => method})

  defp chargeback(id, payment, on),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment,
      "occurred_on" => on
    }

  defp reduce(id, payment, amount, on),
    do: %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment,
      "amount_cents" => amount,
      "occurred_on" => on
    }

  defp transfer(id, source, destination, amount, on),
    do: %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount,
      "occurred_on" => on
    }

  defp operation(id, type, group, on, extra),
    do:
      Map.merge(
        %{"operation_id" => id, "type" => type, "group_id" => group, "occurred_on" => on},
        extra
      )
end
