defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp start(starts_on \\ "2027-01-01") do
    %{
      "operation_id" => "start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "close-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp pay(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp submit(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates closes and remembers applied and rejected results durably" do
    before_start = close("too-soon", "2027-01-01")
    assert [%{"status" => "rejected", "code" => "invalid_period"}] = submit([before_start])

    submit([start("2027-01-10")])

    assert submit([before_start]) == [
             %{
               "operation_id" => "too-soon",
               "status" => "rejected",
               "code" => "invalid_period"
             }
           ]

    assert [%{"code" => "invalid_period"}] = submit([close("before-inception", "2027-01-09")])
    assert [%{"code" => "invalid_period"}] = submit([close("bad-date", "not-a-date")])

    missing_date = Map.delete(close("missing", "2027-01-10"), "period_end_on")
    assert [%{"code" => "invalid_period"}] = submit([missing_date])

    first = close("close-first", "2027-01-10")

    assert submit([first]) == [
             %{
               "operation_id" => "close-first",
               "status" => "applied",
               "period_end_on" => "2027-01-10"
             }
           ]

    assert submit([first]) == submit([first])
    assert [%{"code" => "operation_id_conflict"}] = submit([close("close-first", "2027-01-11")])
    assert [%{"code" => "invalid_period"}] = submit([close("same-cutoff", "2027-01-10")])
    assert [%{"code" => "invalid_period"}] = submit([close("earlier-cutoff", "2027-01-09")])

    assert [%{"status" => "applied", "period_end_on" => "2027-01-12"}] =
             submit([close("close-second", "2027-01-12")])

    assert report("2027-01-12")["status"] == "closed"
    assert report("2027-01-13")["status"] == "open"

    assert get(build_conn(), ~p"/api/v1/operations/close-first") |> json_response(200) == %{
             "data" => %{
               "operation_id" => "close-first",
               "status" => "applied",
               "period_end_on" => "2027-01-10"
             }
           }
  end

  test "same-batch order closes prior movements and moves later backdated effects" do
    assert Enum.all?(
             submit([
               start(),
               open("ordered"),
               pay("before-close", "ordered", 100, "2027-01-02"),
               close("close-jan-2", "2027-01-02"),
               pay("after-close", "ordered", 200, "2027-01-02")
             ]),
             &(&1["status"] == "applied")
           )

    closed = report("2027-01-02")
    assert closed["status"] == "closed"
    assert closed["cash"] == [cash_entry(0, %{"received_cents" => 100}, 100)]
    assert closed["late_adjustments"] == zero_late_adjustments()

    first_open = report("2027-01-03")
    assert first_open["status"] == "open"
    assert first_open["cash"] == [cash_entry(100, %{}, 300)]

    assert first_open["late_adjustments"] == %{
             "cash" => [late_cash(%{"received_cents" => 200})],
             "credit" => zero_credit_movements()
           }

    submit([
      close("close-jan-4", "2027-01-04"),
      pay("already-open-dated", "ordered", 300, "2027-01-05")
    ])

    assert report("2027-01-02") == closed
    already_open_dated = report("2027-01-05")

    assert already_open_dated["cash"] ==
             [cash_entry(300, %{"received_cents" => 300}, 600)]

    assert already_open_dated["late_adjustments"] == zero_late_adjustments()

    submit([close("close-jan-6", "2027-01-06")])
    later_closed = report("2027-01-05")
    assert later_closed["status"] == "closed"
    assert later_closed["cash"] == already_open_dated["cash"]
    assert later_closed["late_adjustments"] == already_open_dated["late_adjustments"]
  end

  test "late chargeback preserves signed classifications even when its net effect is zero" do
    submit([
      start(),
      open("refund-source"),
      pay("refunded-payment", "refund-source", 100, "2027-01-02"),
      %{
        "operation_id" => "refund-before-close",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "refund-source"
      },
      close("close-refund", "2027-01-02")
    ])

    closed = report("2027-01-02")

    submit([
      %{
        "operation_id" => "late-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-01-02",
        "payment_operation_id" => "refunded-payment"
      }
    ])

    day = report("2027-01-03")
    assert day["cash"] == [cash_entry(0, %{}, 0)]

    assert day["late_adjustments"]["cash"] == [
             late_cash(%{"refunded_cents" => -100, "charged_back_cents" => 100})
           ]

    assert report("2027-01-02") == closed
  end

  test "late credit issuance is separated while balances include the complete effect" do
    submit([
      start(),
      open("credit-source"),
      pay("credit-cash", "credit-source", 100, "2027-01-02"),
      close("close-credit-source", "2027-01-02"),
      %{
        "operation_id" => "late-credit-issue",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      }
    ])

    day = report("2027-01-03")
    assert day["cash"] == [cash_entry(100, %{}, 0)]
    assert day["credit"]["opening_liability_cents"] == 0
    assert day["credit"]["movements"] == zero_credit_movements()
    assert day["credit"]["closing_liability_cents"] == 110

    assert day["late_adjustments"] == %{
             "cash" => [late_cash(%{"converted_to_credit_cents" => 100})],
             "credit" => Map.put(zero_credit_movements(), "issued_cents", 110)
           }
  end

  test "late application reverses a previously published expiry on the first open day" do
    submit([
      start(),
      open("expiry-source"),
      pay("expiry-cash", "expiry-source", 100, "2027-01-01"),
      %{
        "operation_id" => "issue-expiring-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "expiry-source",
        "refund_method" => "hotel_credit"
      },
      open("expiry-target", %{
        "operation_id" => "open-expiry-target",
        "rate_plan" => "advance_purchase"
      }),
      close("close-through-expiry", "2028-01-02")
    ])

    expiry_report = report("2028-01-02")
    assert expiry_report["status"] == "closed"
    assert expiry_report["credit"]["movements"]["expired_cents"] == 110
    assert expiry_report["credit"]["closing_liability_cents"] == 0

    assert [%{"status" => "applied"}] =
             submit([
               %{
                 "operation_id" => "late-credit-application",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2028-01-01",
                 "group_id" => "expiry-target",
                 "amount_cents" => 100
               }
             ])

    first_open = report("2028-01-03")
    assert first_open["credit"]["opening_liability_cents"] == 0
    assert first_open["credit"]["movements"] == zero_credit_movements()
    assert first_open["credit"]["closing_liability_cents"] == 100
    assert first_open["late_adjustments"]["credit"]["expired_cents"] == -100
    assert report("2028-01-02") == expiry_report
  end

  defp cash_entry(opening, movement_overrides, closing) do
    %{
      "property_id" => "ams-canal",
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movement_overrides),
      "closing_held_cents" => closing
    }
  end

  defp late_cash(movement_overrides) do
    %{
      "property_id" => "ams-canal",
      "movements" => Map.merge(zero_cash_movements(), movement_overrides)
    }
  end

  defp zero_late_adjustments, do: %{"cash" => [], "credit" => zero_credit_movements()}

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end
end
