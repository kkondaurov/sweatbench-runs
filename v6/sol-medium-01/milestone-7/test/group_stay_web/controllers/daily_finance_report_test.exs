defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "reporting starts from the exact in-batch position and follows durable operation rules", %{
    conn: conn
  } do
    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for path <- [
          "/api/v1/finance/daily-report",
          "/api/v1/finance/daily-report?date=nope"
        ] do
      assert get(conn, path) |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    start = %{
      "operation_id" => "start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-10"
    }

    response =
      post_ops(conn, [
        open("open-before", "before", "guest-a", "z-property"),
        cash("cash-before", "before", 1_000, "2026-10-12"),
        start,
        cash("cash-after", "before", 500, "2026-10-01")
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-10-10"
           }

    assert report(conn, "2026-10-10") == %{
             "date" => "2026-10-10",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "z-property",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(%{"received_cents" => 500}),
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => credit_entry(0, %{}, 0),
             "late_adjustments" => empty_late_adjustments()
           }

    assert %{"results" => [%{"status" => "applied"}]} =
             post_ops(conn, [cash("cash-after", "before", 500, "2026-10-01")])

    assert report(conn, "2026-10-10")["cash"] |> hd() |> Map.fetch!("closing_held_cents") ==
             1_500

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             post_ops(conn, [
               %{
                 "operation_id" => "bad-finance-date",
                 "type" => "record_cash_payment",
                 "occurred_on" => "bad-date",
                 "group_id" => "before",
                 "amount_cents" => 1
               }
             ])

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-09")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert post_ops(conn, [start])["results"] == [Enum.at(response["results"], 2)]

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             post_ops(conn, [Map.put(start, "starts_on", "2026-10-11")])

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             post_ops(conn, [Map.put(start, "operation_id", "start-again")])

    for starts_on <- [nil, "not-a-date", 123] do
      invalid = %{
        "operation_id" => "invalid-start-#{inspect(starts_on)}",
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
      }

      assert %{"results" => [%{"code" => "invalid_reporting_date"}]} = post_ops(conn, [invalid])
    end
  end

  test "cash reports classify transfers, reductions, settlements, and refund reversals by property",
       %{conn: conn} do
    start_reporting(conn, "2026-10-01")

    post_ops(conn, [
      open("open-source", "source", "guest-cash", "z-source"),
      open("open-destination", "destination", "guest-cash", "a-destination"),
      cash("payment", "source", 1_000, "2026-10-02"),
      transfer("move", "source", "destination", 400, "2026-10-03"),
      reduce("reduce", "payment", 100, "2026-10-04"),
      cancel("refund", "destination", "2026-10-05"),
      chargeback("chargeback", "payment", "2026-10-06")
    ])

    assert [destination, source] = report(conn, "2026-10-03")["cash"]
    assert destination["property_id"] == "a-destination"
    assert destination["movements"] == cash_movements(%{"transferred_in_cents" => 400})
    assert source["property_id"] == "z-source"
    assert source["movements"] == cash_movements(%{"transferred_out_cents" => 400})

    entry =
      report(conn, "2026-10-04")["cash"]
      |> Enum.find(&(&1["property_id"] == "a-destination"))

    assert entry["property_id"] == "a-destination"
    assert entry["opening_held_cents"] == 400
    assert entry["movements"] == cash_movements(%{"reduced_cents" => 100})
    assert entry["closing_held_cents"] == 300

    entry =
      report(conn, "2026-10-05")["cash"]
      |> Enum.find(&(&1["property_id"] == "a-destination"))

    assert entry["movements"] == cash_movements(%{"refunded_cents" => 300})
    assert entry["closing_held_cents"] == 0

    assert [destination, source] = report(conn, "2026-10-06")["cash"]

    assert destination["movements"] ==
             cash_movements(%{"refunded_cents" => -300, "charged_back_cents" => 300})

    assert destination["closing_held_cents"] == 0
    assert source["movements"] == cash_movements(%{"charged_back_cents" => 600})
    assert source["closing_held_cents"] == 0

    # Reading repeatedly and out of order has no effect on either reports or current views.
    old_report = report(conn, "2026-10-02")
    current_ledger = ledger(conn)
    assert report(conn, "2026-10-06") == report(conn, "2026-10-06")
    assert report(conn, "2026-10-02") == old_report
    assert ledger(conn) == current_ledger
  end

  test "same-property transfers expose both balanced movement columns", %{conn: conn} do
    start_reporting(conn, "2026-10-01")

    post_ops(conn, [
      open("open-one", "one", "guest-same", "same-property"),
      open("open-two", "two", "guest-same", "same-property"),
      cash("same-cash", "one", 500, "2026-10-02"),
      transfer("same-transfer", "one", "two", 300, "2026-10-03")
    ])

    assert [entry] = report(conn, "2026-10-03")["cash"]

    assert entry["movements"] ==
             cash_movements(%{
               "transferred_in_cents" => 300,
               "transferred_out_cents" => 300
             })

    assert entry["opening_held_cents"] == 500
    assert entry["closing_held_cents"] == 500
  end

  test "credit reports issue, consumption, and idle-day expiry without mutating credit", %{
    conn: conn
  } do
    start_reporting(conn, "2026-10-01")

    post_ops(conn, [
      open("open-origin", "origin", "guest-credit", "origin-property"),
      cash("origin-payment", "origin", 1_000, "2026-10-02"),
      cancel("issue", "origin", "2026-10-02", "hotel_credit"),
      open("open-flex", "flex", "guest-credit", "flex-property"),
      credit("apply-flex", "flex", 600, "2026-10-03"),
      cancel("restore-flex", "flex", "2026-10-04"),
      open("open-advance", "advance", "guest-credit", "advance-property", "advance_purchase"),
      credit("apply-advance", "advance", 500, "2026-10-05"),
      cancel("consume-advance", "advance", "2026-10-06")
    ])

    assert report(conn, "2026-10-02")["credit"] ==
             credit_entry(0, %{"issued_cents" => 1_100}, 1_100)

    assert report(conn, "2026-10-03")["credit"] == credit_entry(1_100, %{}, 1_100)
    assert report(conn, "2026-10-04")["credit"] == credit_entry(1_100, %{}, 1_100)

    assert report(conn, "2026-10-06")["credit"] ==
             credit_entry(1_100, %{"consumed_cents" => 500}, 600)

    before = credit_balance(conn, "guest-credit", "2027-10-03")

    assert report(conn, "2027-10-03")["credit"] ==
             credit_entry(600, %{"expired_cents" => 600}, 0)

    assert credit_balance(conn, "guest-credit", "2027-10-03") == before
  end

  test "chargebacks distinguish available revocation from applied-credit absorption", %{
    conn: conn
  } do
    start_reporting(conn, "2026-10-01")

    post_ops(conn, [
      open("open-revoke", "revoke", "guest-revoke", "revoke-property"),
      cash("pay-revoke", "revoke", 1_000, "2026-10-02"),
      cancel("issue-revoke", "revoke", "2026-10-02", "hotel_credit"),
      chargeback("charge-revoke", "pay-revoke", "2026-10-03")
    ])

    assert report(conn, "2026-10-03")["credit"] ==
             credit_entry(1_100, %{"revoked_cents" => 1_100}, 0)

    post_ops(conn, [
      open("open-absorb-origin", "absorb-origin", "guest-absorb", "absorb-origin-property"),
      cash("pay-absorb", "absorb-origin", 1_000, "2026-10-04"),
      cancel("issue-absorb", "absorb-origin", "2026-10-04", "hotel_credit"),
      open("open-absorb-target", "absorb-target", "guest-absorb", "absorb-target-property"),
      credit("apply-absorb", "absorb-target", 1_100, "2026-10-05"),
      chargeback("charge-absorb", "pay-absorb", "2026-10-06"),
      cancel("restore-absorb", "absorb-target", "2026-10-07")
    ])

    assert report(conn, "2026-10-06")["credit"] == credit_entry(1_100, %{}, 1_100)

    assert report(conn, "2026-10-07")["credit"] ==
             credit_entry(1_100, %{"absorbed_cents" => 1_100}, 0)
  end

  test "backdated credit that is already expired is issued and expired on the clamped posting day",
       %{conn: conn} do
    start_reporting(conn, "2027-10-10")

    post_ops(conn, [
      open("open-old-credit", "old-credit", "guest-old", "old-property"),
      cash("pay-old-credit", "old-credit", 1_000, "2026-10-01"),
      cancel("issue-old-credit", "old-credit", "2026-10-01", "hotel_credit")
    ])

    assert report(conn, "2027-10-10")["credit"] ==
             credit_entry(
               0,
               %{"issued_cents" => 1_100, "expired_cents" => 1_100},
               0
             )
  end

  defp start_reporting(conn, starts_on) do
    post_ops(conn, [
      %{
        "operation_id" => "start-#{starts_on}",
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
      }
    ])
  end

  defp report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn), do: get(conn, "/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  defp credit_balance(conn, guest_id, on) do
    get(conn, "/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp post_ops(conn, operations) do
    conn |> post("/api/v1/partner-batches", %{operations: operations}) |> json_response(200)
  end

  defp open(operation_id, group_id, guest_id, property_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp reduce(operation_id, payment_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id,
      "amount_cents" => amount
    }
  end

  defp chargeback(operation_id, payment_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }
  end

  defp cancel(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp credit(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
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

  defp credit_entry(opening, overrides, closing) do
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

  defp empty_late_adjustments do
    %{
      "cash" => [],
      "credit" => %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      }
    }
  end
end
