defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group, property \\ "ams-canal", rate \\ 10_000) do
    %{
      "operation_id" => id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group,
      "guest_id" => "guest",
      "property_id" => property,
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => rate}]
    }
  end

  defp pay(id, group, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp close(id, period_end_on) do
    %{
      "operation_id" => id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp start do
    %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-02-01"
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates closes and durably replays applied and rejected results", %{conn: conn} do
    assert [rejected = %{"code" => "invalid_period"}] =
             submit(conn, [close("before-start", "2027-02-01")])

    assert [^rejected] = submit(conn, [close("before-start", "2027-02-01")])

    submit(conn, [start()])

    for operation <- [
          close("missing", nil) |> Map.delete("period_end_on"),
          close("bad", "not-a-date"),
          close("too-early", "2027-01-31")
        ] do
      assert [%{"code" => "invalid_period"}] = submit(conn, [operation])
    end

    operation = close("close", "2027-02-01")

    assert [result] = submit(conn, [operation])

    assert result == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2027-02-01"
           }

    assert map_size(result) == 3
    assert [^result] = submit(conn, [operation])

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [close("close", "2027-02-02")])

    assert [%{"code" => "invalid_period"}] = submit(conn, [close("same", "2027-02-01")])
    assert [%{"code" => "invalid_period"}] = submit(conn, [close("earlier", "2027-01-31")])
  end

  test "same-batch close freezes earlier days and moves later old-dated effects forward", %{
    conn: conn
  } do
    assert [_, _, _, _, _] =
             submit(conn, [
               start(),
               open("open", "group"),
               pay("before", "group", 1_000, "2027-02-02"),
               close("close", "2027-02-02"),
               pay("after", "group", 500, "2027-02-01")
             ])

    closed = report(conn, "2027-02-02")

    assert closed["status"] == "closed"
    assert [%{"movements" => %{"received_cents" => 1_000}}] = closed["cash"]

    assert closed["late_adjustments"] == %{
             "cash" => [],
             "credit" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
           }

    first_open = report(conn, "2027-02-03")
    assert first_open["status"] == "open"

    assert [cash] = first_open["cash"]
    assert cash["opening_held_cents"] == 1_000
    assert cash["closing_held_cents"] == 1_500
    assert Enum.all?(cash["movements"], fn {_field, amount} -> amount == 0 end)

    assert first_open["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => %{
                 "received_cents" => 500,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
           ]

    submit(conn, [pay("ordinary", "group", 100, "2027-02-04"), close("close-2", "2027-02-03")])

    assert report(conn, "2027-02-02") == closed
    assert report(conn, "2027-02-03")["status"] == "closed"

    assert [%{"movements" => %{"received_cents" => 100}}] =
             report(conn, "2027-02-04")["cash"]
  end

  test "a late chargeback preserves signed zero-net classifications", %{conn: conn} do
    submit(conn, [
      start(),
      open("open", "group", "ams-canal", 500),
      pay("pay", "group", 100, "2027-02-02"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "group"
      },
      close("close", "2027-02-04"),
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-02-01",
        "payment_operation_id" => "pay"
      }
    ])

    day = report(conn, "2027-02-05")
    assert [%{"opening_held_cents" => 0, "closing_held_cents" => 0} = cash] = day["cash"]
    assert Enum.all?(cash["movements"], fn {_field, amount} -> amount == 0 end)

    assert [%{"movements" => movements}] = day["late_adjustments"]["cash"]
    assert movements["refunded_cents"] == -100
    assert movements["charged_back_cents"] == 100
  end

  test "late credit conversion is separated while balances use the complete effect", %{conn: conn} do
    submit(conn, [
      start(),
      open("open", "group", "ams-canal", 500),
      pay("pay", "group", 100, "2027-02-02"),
      close("close", "2027-02-03"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-02",
        "group_id" => "group",
        "refund_method" => "hotel_credit"
      }
    ])

    day = report(conn, "2027-02-04")
    assert day["credit"]["movements"]["issued_cents"] == 0
    assert day["credit"]["opening_liability_cents"] == 0
    assert day["credit"]["closing_liability_cents"] == 110
    assert day["late_adjustments"]["credit"]["issued_cents"] == 110

    assert [%{"movements" => movements}] = day["late_adjustments"]["cash"]
    assert movements["converted_to_credit_cents"] == 100
  end

  test "late issuance beyond the lot expiry reports both signed classifications", %{conn: conn} do
    submit(conn, [
      start(),
      open("open", "group", "ams-canal", 500),
      pay("pay", "group", 100, "2027-02-02"),
      close("close", "2028-03-01"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-02",
        "group_id" => "group",
        "refund_method" => "hotel_credit"
      }
    ])

    day = report(conn, "2028-03-02")
    assert day["credit"]["opening_liability_cents"] == 0
    assert day["credit"]["closing_liability_cents"] == 0
    assert day["late_adjustments"]["credit"]["issued_cents"] == 110
    assert day["late_adjustments"]["credit"]["expired_cents"] == 110

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2028-03-02") |> json_response(200)
  end
end
