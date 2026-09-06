defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  @zero_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @zero_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  test "validates increasing periods and durably replays exact close results", %{conn: conn} do
    rejected_before_start = close_operation("close-before-start", "2027-02-01")

    assert %{"results" => [%{"code" => "invalid_period", "status" => "rejected"}]} =
             conn |> post_batch([rejected_before_start]) |> json_response(200)

    start_reporting("2027-02-01")

    assert build_conn() |> post_batch([rejected_before_start]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    for operation <- [
          close_operation("close-before-inception", "2027-01-31"),
          close_operation("close-invalid-date", "2027-02-30"),
          %{"operation_id" => "close-missing-date", "type" => "close_finance_period"}
        ] do
      assert %{"results" => [%{"code" => "invalid_period"}]} =
               build_conn() |> post_batch([operation]) |> json_response(200)
    end

    first_close =
      close_operation("close-first", "2027-02-01")
      |> Map.put("expected_revision", 999)

    first_result = %{
      "operation_id" => "close-first",
      "status" => "applied",
      "period_end_on" => "2027-02-01"
    }

    assert build_conn() |> post_batch([first_close]) |> json_response(200) == %{
             "results" => [first_result]
           }

    for operation <- [
          close_operation("close-same", "2027-02-01"),
          close_operation("close-earlier", "2027-01-31")
        ] do
      assert %{"results" => [%{"code" => "invalid_period"}]} =
               build_conn() |> post_batch([operation]) |> json_response(200)
    end

    assert build_conn()
           |> post_batch([close_operation("close-later", "2027-02-03")])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close-later",
                 "status" => "applied",
                 "period_end_on" => "2027-02-03"
               }
             ]
           }

    assert build_conn() |> post_batch([first_close]) |> json_response(200) == %{
             "results" => [first_result]
           }

    assert build_conn()
           |> post_batch([Map.put(first_close, "period_end_on", "2027-02-04")])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close-first",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert get(build_conn(), "/api/v1/operations/close-first") |> json_response(200) == %{
             "data" => first_result
           }

    assert get_report("2027-02-03")["data"] == %{
             "date" => "2027-02-03",
             "status" => "closed",
             "cash" => [],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => @zero_credit_movements,
               "closing_liability_cents" => 0
             },
             "late_adjustments" => %{
               "cash" => [],
               "credit" => @zero_credit_movements
             }
           }

    assert get_report("2027-02-04")["data"]["status"] == "open"
  end

  test "same-batch close ordering clamps only later old-dated effects and freezes closed days", %{
    conn: conn
  } do
    operations = [
      start_operation("2027-02-01"),
      open_operation("open-group", "group", "ams-canal", "flexible", 1_000),
      payment_operation("before-close", "group", 40, "2027-01-20"),
      close_operation("close-first-day", "2027-02-01"),
      payment_operation("after-close", "group", 30, "2027-01-20"),
      payment_operation("future-payment", "group", 20, "2027-02-03")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    frozen_first_day = get_report("2027-02-01")["data"]
    assert frozen_first_day["status"] == "closed"
    assert [first_day_cash] = frozen_first_day["cash"]
    assert first_day_cash["movements"]["received_cents"] == 40
    assert frozen_first_day["late_adjustments"] == zero_late_adjustments()

    reduction = %{
      "operation_id" => "late-reduction",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-21",
      "payment_operation_id" => "before-close",
      "amount_cents" => 10
    }

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn() |> post_batch([reduction]) |> json_response(200)

    second_day = get_report("2027-02-02")["data"]
    assert second_day["status"] == "open"
    assert [cash] = second_day["cash"]
    assert cash["opening_held_cents"] == 40
    assert cash["movements"] == @zero_cash_movements
    assert cash["closing_held_cents"] == 60

    assert second_day["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" =>
                 @zero_cash_movements
                 |> Map.put("received_cents", 30)
                 |> Map.put("reduced_cents", 10)
             }
           ]

    assert second_day["late_adjustments"]["credit"] == @zero_credit_movements
    assert get_report("2027-02-01")["data"] == frozen_first_day

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([close_operation("close-second-day", "2027-02-02")])
             |> json_response(200)

    frozen_second_day = get_report("2027-02-02")["data"]
    assert frozen_second_day["status"] == "closed"

    chargeback = %{
      "operation_id" => "late-chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-22",
      "payment_operation_id" => "after-close"
    }

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn() |> post_batch([chargeback]) |> json_response(200)

    assert get_report("2027-02-01")["data"] == frozen_first_day
    assert get_report("2027-02-02")["data"] == frozen_second_day

    third_day = get_report("2027-02-03")["data"]
    assert [third_day_cash] = third_day["cash"]
    assert third_day_cash["opening_held_cents"] == 60
    assert third_day_cash["movements"]["received_cents"] == 20
    assert third_day_cash["closing_held_cents"] == 50

    assert get_in(third_day, ["late_adjustments", "cash", Access.at(0), "movements"]) ==
             Map.put(@zero_cash_movements, "charged_back_cents", 30)

    assert get_group("group")["data"]["cash_paid_cents"] == 50
    assert get_ledger()["data"]["cash_held_cents"] == 50
  end

  test "retains signed zero-net late classifications and their cash property", %{conn: conn} do
    operations = [
      start_operation("2027-01-01"),
      open_operation("open-refund", "refund", "zrh-center", "flexible", 500),
      payment_operation("refunded-payment", "refund", 100, "2027-01-01"),
      cancel_operation("refund-payment", "refund", "2027-01-02"),
      close_operation("close-refund", "2027-01-02")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    frozen_refund = get_report("2027-01-02")["data"]

    chargeback = %{
      "operation_id" => "chargeback-refund",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-02",
      "payment_operation_id" => "refunded-payment"
    }

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn() |> post_batch([chargeback]) |> json_response(200)

    report = get_report("2027-01-03")["data"]
    assert [ordinary] = report["cash"]
    assert ordinary["property_id"] == "zrh-center"
    assert ordinary["opening_held_cents"] == 0
    assert ordinary["movements"] == @zero_cash_movements
    assert ordinary["closing_held_cents"] == 0

    assert [late] = report["late_adjustments"]["cash"]
    assert late["property_id"] == "zrh-center"

    assert late["movements"] ==
             @zero_cash_movements
             |> Map.put("refunded_cents", -100)
             |> Map.put("charged_back_cents", 100)

    assert get_report("2027-01-02")["data"] == frozen_refund
    assert get_ledger()["data"]["cash_charged_back_cents"] == 100
  end

  test "orders both property legs of a late transfer without changing ledger totals", %{
    conn: conn
  } do
    operations = [
      start_operation("2027-03-01"),
      open_operation("open-source", "source", "zrh-center", "flexible", 500),
      open_operation("open-destination", "destination", "ams-canal", "flexible", 500),
      payment_operation("transfer-payment", "source", 100, "2027-03-01"),
      close_operation("close-transfer-day", "2027-03-01"),
      %{
        "operation_id" => "late-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2027-03-01",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 60
      }
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    report = get_report("2027-03-02")["data"]
    assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "zrh-center"]

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => Map.put(@zero_cash_movements, "transferred_in_cents", 60)
             },
             %{
               "property_id" => "zrh-center",
               "movements" => Map.put(@zero_cash_movements, "transferred_out_cents", 60)
             }
           ]

    assert get_ledger()["data"]["cash_held_cents"] == 100
  end

  test "clamps a closed passive-expiry reversal and reports it as late", %{conn: conn} do
    operations = [
      start_operation("2027-01-01"),
      open_operation("open-source", "source", "ams-canal", "flexible", 500),
      payment_operation("source-payment", "source", 100, "2027-01-01"),
      cancel_operation("issue-lot", "source", "2027-01-02", "hotel_credit"),
      open_operation("open-target", "target", "ber-mitte", "advance_purchase", 60),
      close_operation("close-through-expiry", "2028-01-03")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    frozen_expiry = get_report("2028-01-03")["data"]
    assert frozen_expiry["credit"]["movements"]["expired_cents"] == 110

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([credit_operation("late-credit-use", "target", 60, "2028-01-02")])
             |> json_response(200)

    report = get_report("2028-01-04")["data"]

    assert report["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => @zero_credit_movements,
             "closing_liability_cents" => 60
           }

    assert report["late_adjustments"]["credit"] ==
             Map.put(@zero_credit_movements, "expired_cents", -60)

    assert get_report("2028-01-03")["data"] == frozen_expiry
    assert get_ledger("2028-01-04")["data"]["credit_liability_cents"] == 60
  end

  test "marks a late credit issue but leaves its future passive expiry ordinary", %{conn: conn} do
    operations = [
      start_operation("2027-01-01"),
      open_operation("open-late-source", "late-source", "ams-canal", "flexible", 500),
      payment_operation("late-source-payment", "late-source", 100, "2027-01-01"),
      close_operation("close-before-credit", "2027-01-02"),
      cancel_operation("late-credit-issue", "late-source", "2027-01-02", "hotel_credit")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    issue_day = get_report("2027-01-03")["data"]
    assert issue_day["credit"]["movements"] == @zero_credit_movements
    assert issue_day["credit"]["closing_liability_cents"] == 110

    assert issue_day["late_adjustments"]["credit"] ==
             Map.put(@zero_credit_movements, "issued_cents", 110)

    assert get_in(issue_day, ["late_adjustments", "cash", Access.at(0), "movements"]) ==
             Map.put(@zero_cash_movements, "converted_to_credit_cents", 100)

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([close_operation("close-through-future-expiry", "2028-01-03")])
             |> json_response(200)

    expiry_day = get_report("2028-01-03")["data"]
    assert expiry_day["status"] == "closed"
    assert expiry_day["credit"]["movements"]["expired_cents"] == 110
    assert expiry_day["late_adjustments"] == zero_late_adjustments()
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp get_report(date),
    do:
      build_conn()
      |> get("/api/v1/finance/daily-report?date=#{date}")
      |> json_response(200)

  defp get_group(group_id),
    do: build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)

  defp get_ledger(date \\ nil) do
    path = if date, do: "/api/v1/ledger?on=#{date}", else: "/api/v1/ledger"
    build_conn() |> get(path) |> json_response(200)
  end

  defp start_reporting(starts_on) do
    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn() |> post_batch([start_operation(starts_on)]) |> json_response(200)
  end

  defp start_operation(starts_on) do
    %{
      "operation_id" => "start-#{starts_on}",
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_operation(operation_id, group_id, property_id, rate_plan, rate) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "period-close-guest",
      "property_id" => property_id,
      "arrival_on" => "2028-12-01",
      "departure_on" => "2028-12-02",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => rate}]
    }
  end

  defp payment_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, refund_method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put("refund_method", refund_method)
  end

  defp zero_late_adjustments,
    do: %{"cash" => [], "credit" => @zero_credit_movements}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
