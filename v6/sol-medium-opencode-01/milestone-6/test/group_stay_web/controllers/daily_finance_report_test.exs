defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, property_id \\ "hotel-b", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-12-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => property_id,
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp pay(group_id, operation_id, amount, occurred_on \\ "2027-01-01") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp start(operation_id \\ "start", starts_on \\ "2027-01-01") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp submit(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{operations: operations})

  defp report(conn, date, status \\ 200) do
    get(recycle(conn), ~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(status)
  end

  test "validates inception and report dates and preserves the exact start result", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             report(conn, "not-a-date", 422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             report(conn, "2027-01-01", 404)

    conn = submit(conn, [%{"operation_id" => "bad", "type" => "start_finance_reporting"}])

    assert %{
             "results" => [
               %{
                 "operation_id" => "bad",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           } = json_response(conn, 200)

    conn = submit(recycle(conn), [start(), start(), start("other")])

    assert %{"results" => [applied, replayed, rejected]} = json_response(conn, 200)

    assert applied == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-01"
           }

    assert replayed == applied

    assert rejected == %{
             "operation_id" => "other",
             "status" => "rejected",
             "code" => "reporting_already_started"
           }

    assert %{"error" => %{"code" => "report_not_available"}} =
             report(conn, "2026-12-31", 404)

    assert report(conn, "2027-01-01") == %{
             "data" => %{
               "date" => "2027-01-01",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           }
  end

  test "takes the opening position in processing order and clamps later posting dates", %{
    conn: conn
  } do
    conn =
      submit(conn, [
        open("group-b"),
        pay("group-b", "opening-payment", 1_000, "2028-01-01"),
        start(),
        pay("group-b", "same-day-payment", 500, "2026-01-01"),
        pay("group-b", "future-payment", 500, "2027-01-02")
      ])

    assert %{"data" => day_one} = report(conn, "2027-01-01")

    assert day_one["cash"] == [
             %{
               "property_id" => "hotel-b",
               "opening_held_cents" => 1_000,
               "movements" => cash_movements(received_cents: 500),
               "closing_held_cents" => 1_500
             }
           ]

    assert %{"data" => day_two} = report(conn, "2027-01-02")
    assert [cash] = day_two["cash"]
    assert cash["opening_held_cents"] == 1_500
    assert cash["movements"] == cash_movements(received_cents: 500)
    assert cash["closing_held_cents"] == 2_000

    assert %{"data" => later} = report(conn, "2027-02-01")
    assert [cash] = later["cash"]
    assert cash["opening_held_cents"] == 2_000
    assert cash["movements"] == cash_movements([])

    assert report(conn, "2027-01-01") == %{"data" => day_one}
  end

  test "durable retries and rejected operations do not add movements", %{conn: conn} do
    payment = pay("group", "payment", 1_000)
    rejected = pay("group", "too-much", 2_000)

    conn = submit(conn, [open("group"), start(), payment, payment, rejected])

    assert %{"results" => [_open, _start, applied, replayed, rejection]} =
             json_response(conn, 200)

    assert replayed == applied
    assert rejection["status"] == "rejected"

    assert %{"data" => day} = report(conn, "2027-01-01")
    assert [cash] = day["cash"]
    assert cash["movements"] == cash_movements(received_cents: 1_000)
    assert cash["closing_held_cents"] == 1_000
  end

  test "reports transfers, reductions, refunds, and signed chargeback reversals by property", %{
    conn: conn
  } do
    transfer = %{
      "operation_id" => "move",
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-02",
      "source_group_id" => "source",
      "destination_group_id" => "destination",
      "amount_cents" => 1_000
    }

    reduce = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-03",
      "payment_operation_id" => "payment",
      "amount_cents" => 250
    }

    cancel = %{
      "operation_id" => "refund",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-04",
      "group_id" => "destination"
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => "payment"
    }

    conn =
      submit(conn, [
        open("source", "hotel-b"),
        open("destination", "hotel-a"),
        start(),
        pay("source", "payment", 1_500),
        transfer,
        reduce,
        cancel,
        chargeback
      ])

    assert %{"data" => transfer_day} = report(conn, "2027-01-02")
    assert Enum.map(transfer_day["cash"], & &1["property_id"]) == ["hotel-a", "hotel-b"]

    assert Enum.at(transfer_day["cash"], 0)["movements"] ==
             cash_movements(transferred_in_cents: 1_000)

    assert Enum.at(transfer_day["cash"], 1)["movements"] ==
             cash_movements(transferred_out_cents: 1_000)

    assert %{"data" => reduction_day} = report(conn, "2027-01-03")
    destination = Enum.find(reduction_day["cash"], &(&1["property_id"] == "hotel-a"))
    assert destination["movements"] == cash_movements(reduced_cents: 250)

    assert %{"data" => refund_day} = report(conn, "2027-01-04")
    destination = Enum.find(refund_day["cash"], &(&1["property_id"] == "hotel-a"))
    assert destination["movements"] == cash_movements(refunded_cents: 750)

    assert %{"data" => chargeback_day} = report(conn, "2027-01-05")
    destination = Enum.find(chargeback_day["cash"], &(&1["property_id"] == "hotel-a"))

    assert destination["movements"] ==
             cash_movements(refunded_cents: -750, charged_back_cents: 750)

    source = Enum.find(chargeback_day["cash"], &(&1["property_id"] == "hotel-b"))
    assert source["movements"] == cash_movements(charged_back_cents: 500)
    assert destination["closing_held_cents"] == 0
    assert source["closing_held_cents"] == 0
  end

  test "reports credit issuance and natural expiry without mutating on reads", %{conn: conn} do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "origin",
      "refund_method" => "hotel_credit"
    }

    conn = submit(conn, [open("origin"), pay("origin", "payment", 1_000), start(), convert])

    assert %{"data" => issued_day} = report(conn, "2027-01-02")

    assert issued_day["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(issued_cents: 1_100),
             "closing_liability_cents" => 1_100
           }

    assert %{"data" => expiry_day} = report(conn, "2028-01-03")

    assert expiry_day["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(expired_cents: 1_100),
             "closing_liability_cents" => 0
           }

    assert report(conn, "2028-01-03") == %{"data" => expiry_day}
    assert report(conn, "2027-01-02") == %{"data" => issued_day}
  end

  test "pauses expiry while credit is applied and reports an expired restoration", %{conn: conn} do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "origin",
      "refund_method" => "hotel_credit"
    }

    apply_credit = %{
      "operation_id" => "apply",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-03",
      "group_id" => "target",
      "amount_cents" => 1_100
    }

    restore = %{
      "operation_id" => "restore",
      "type" => "cancel_group",
      "occurred_on" => "2028-01-04",
      "group_id" => "target"
    }

    target =
      open("target", "hotel-a", %{
        "arrival_on" => "2030-01-01",
        "departure_on" => "2030-01-02"
      })

    conn =
      submit(conn, [
        open("origin"),
        pay("origin", "payment", 1_000),
        target,
        start(),
        convert,
        apply_credit,
        restore
      ])

    assert %{"data" => expiry_day} = report(conn, "2028-01-03")
    assert expiry_day["credit"]["movements"] == credit_movements([])
    assert expiry_day["credit"]["closing_liability_cents"] == 1_100

    assert %{"data" => restoration_day} = report(conn, "2028-01-04")

    assert restoration_day["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(expired_cents: 1_100),
             "closing_liability_cents" => 0
           }
  end

  test "reports available credit revocation and cash conversion reversal on chargeback", %{
    conn: conn
  } do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "origin",
      "refund_method" => "hotel_credit"
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-03",
      "payment_operation_id" => "payment"
    }

    conn =
      submit(conn, [open("origin"), pay("origin", "payment", 1_000), start(), convert, chargeback])

    assert %{"data" => day} = report(conn, "2027-01-03")
    assert day["credit"]["movements"] == credit_movements(revoked_cents: 1_100)
    assert day["credit"]["closing_liability_cents"] == 0

    assert [cash] = day["cash"]

    assert cash["movements"] ==
             cash_movements(converted_to_credit_cents: -1_000, charged_back_cents: 1_000)
  end

  test "expires backdated issuance on the clamped posting date", %{conn: conn} do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2025-01-01",
      "group_id" => "origin",
      "refund_method" => "hotel_credit"
    }

    conn = submit(conn, [open("origin"), pay("origin", "payment", 1_000), start(), convert])

    assert %{"data" => day} = report(conn, "2027-01-01")

    assert day["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(issued_cents: 1_100, expired_cents: 1_100),
             "closing_liability_cents" => 0
           }
  end

  test "reports consumption and shortfall absorption for applied credit", %{conn: conn} do
    convert = fn id, group_id, date ->
      %{
        "operation_id" => id,
        "type" => "cancel_group",
        "occurred_on" => date,
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    end

    apply_credit = fn id, group_id, amount, date ->
      %{
        "operation_id" => id,
        "type" => "apply_hotel_credit",
        "occurred_on" => date,
        "group_id" => group_id,
        "amount_cents" => amount
      }
    end

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-04",
      "payment_operation_id" => "payment-2"
    }

    cancel_absorbed = %{
      "operation_id" => "cancel-absorbed",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-05",
      "group_id" => "target-2"
    }

    advance =
      open("advance", "hotel-a", %{
        "rate_plan" => "advance_purchase",
        "nightly_rate_cents" => 10_000
      })

    conn =
      submit(conn, [
        open("origin-1"),
        pay("origin-1", "payment-1", 1_000),
        convert.("convert-1", "origin-1", "2026-12-02"),
        advance,
        open("origin-2"),
        pay("origin-2", "payment-2", 1_000),
        open("target-2"),
        start(),
        apply_credit.("apply-1", "advance", 1_100, "2027-01-01"),
        %{
          "operation_id" => "consume",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "advance"
        },
        convert.("convert-2", "origin-2", "2027-01-03"),
        apply_credit.("apply-2", "target-2", 1_100, "2027-01-03"),
        chargeback,
        cancel_absorbed
      ])

    assert %{"data" => consumed_day} = report(conn, "2027-01-02")
    assert consumed_day["credit"]["movements"] == credit_movements(consumed_cents: 1_100)

    assert %{"data" => absorbed_day} = report(conn, "2027-01-05")
    assert absorbed_day["credit"]["movements"] == credit_movements(absorbed_cents: 1_100)
  end

  defp cash_movements(overrides) do
    defaults = %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }

    Enum.reduce(overrides, defaults, fn {key, value}, result ->
      Map.put(result, Atom.to_string(key), value)
    end)
  end

  defp credit_movements(overrides) do
    defaults = %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }

    Enum.reduce(overrides, defaults, fn {key, value}, result ->
      Map.put(result, Atom.to_string(key), value)
    end)
  end
end
