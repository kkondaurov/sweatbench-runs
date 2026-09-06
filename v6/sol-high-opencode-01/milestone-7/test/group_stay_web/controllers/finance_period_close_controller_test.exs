defmodule GroupStayWeb.FinancePeriodCloseControllerTest do
  use GroupStayWeb.ConnCase

  test "validates monotonic closes and durably replays an applied close", %{conn: conn} do
    close = close_operation("close", "2027-01-10")

    assert %{
             "results" => [
               before_start,
               started,
               missing_date,
               invalid_date,
               before_inception,
               no_first_open_day,
               applied,
               same_cutoff,
               earlier_cutoff,
               replayed,
               conflict
             ]
           } =
             conn
             |> post_batch([
               close_operation("before-start", "2027-01-10"),
               start_operation("start", "2027-01-10"),
               %{"operation_id" => "missing", "type" => "close_finance_period"},
               close_operation("invalid", "not-a-date"),
               close_operation("before-inception", "2027-01-09"),
               close_operation("no-first-open-day", "25252734927766554-07-27"),
               close,
               close_operation("same", "2027-01-10"),
               close_operation("earlier", "2027-01-09"),
               close,
               close_operation("close", "2027-01-11")
             ])
             |> json_response(200)

    assert before_start["code"] == "invalid_period"
    assert started["status"] == "applied"
    assert missing_date["code"] == "invalid_period"
    assert invalid_date["code"] == "invalid_period"
    assert before_inception["code"] == "invalid_period"
    assert no_first_open_day["code"] == "invalid_period"

    assert applied == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2027-01-10"
           }

    assert same_cutoff["code"] == "invalid_period"
    assert earlier_cutoff["code"] == "invalid_period"
    assert replayed == applied
    assert conflict["code"] == "operation_id_conflict"

    assert %{"data" => ^applied} =
             build_conn()
             |> get("/api/v1/operations/close")
             |> json_response(200)
  end

  test "closes reports and posts old-dated operations on the first open day", %{conn: conn} do
    assert %{"results" => results} =
             conn
             |> post_batch([
               start_operation("start", "2027-01-10"),
               open_operation("group", "guest", "ams-canal"),
               payment_operation("before-close", "group", 100, "2027-01-09"),
               close_operation("close-10", "2027-01-10")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    closed_tenth = get_report("2027-01-10")

    assert closed_tenth == %{
             "date" => "2027-01-10",
             "status" => "closed",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 100}),
                 "closing_held_cents" => 100
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" => late_adjustments()
           }

    assert %{"results" => later_results} =
             build_conn()
             |> post_batch([
               payment_operation("late-on-11", "group", 50, "2027-01-09"),
               close_operation("close-11", "2027-01-11"),
               payment_operation("late-on-12", "group", 25, "2027-01-09"),
               payment_operation("ordinary-on-12", "group", 30, "2027-01-12")
             ])
             |> json_response(200)

    assert Enum.all?(later_results, &(&1["status"] == "applied"))
    assert get_report("2027-01-10") == closed_tenth

    assert get_report("2027-01-11") == %{
             "date" => "2027-01-11",
             "status" => "closed",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 100,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 150
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments([
                 %{
                   "property_id" => "ams-canal",
                   "movements" => cash_movements(%{"received_cents" => 50})
                 }
               ])
           }

    assert get_report("2027-01-12") == %{
             "date" => "2027-01-12",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 150,
                 "movements" => cash_movements(%{"received_cents" => 30}),
                 "closing_held_cents" => 205
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments([
                 %{
                   "property_id" => "ams-canal",
                   "movements" => cash_movements(%{"received_cents" => 25})
                 }
               ])
           }
  end

  test "keeps signed late chargeback classifications when their net effect is zero", %{conn: conn} do
    assert %{"results" => results} =
             conn
             |> post_batch([
               start_operation("start", "2027-01-01"),
               open_operation("group", "guest", "ams-canal"),
               payment_operation("payment", "group", 100, "2027-01-02"),
               cancel_operation("refund", "group", "2027-01-03"),
               close_operation("close", "2027-01-03"),
               chargeback_operation("chargeback", "payment", "2027-01-03")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2027-01-04") == %{
             "date" => "2027-01-04",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments([
                 %{
                   "property_id" => "ams-canal",
                   "movements" =>
                     cash_movements(%{
                       "refunded_cents" => -100,
                       "charged_back_cents" => 100
                     })
                 }
               ])
           }

    assert %{
             "data" => %{
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 100
             }
           } = build_conn() |> get("/api/v1/ledger") |> json_response(200)
  end

  test "classifies an expiry moved out of a closed period as late", %{conn: conn} do
    assert %{"results" => results} =
             conn
             |> post_batch([
               open_operation("source", "guest", "ams-canal"),
               payment_operation("payment", "source", 100, "2027-01-01"),
               start_operation("start", "2027-01-01"),
               close_operation("close", "2028-01-03"),
               cancel_for_credit_operation("issue", "source", "2027-01-02")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2028-01-04") == %{
             "date" => "2028-01-04",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 100,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments(
                 [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => cash_movements(%{"converted_to_credit_cents" => 100})
                   }
                 ],
                 %{"issued_cents" => 110, "expired_cents" => 110}
               )
           }
  end

  test "keeps a future natural expiry ordinary after a late issuance", %{conn: conn} do
    assert %{"results" => results} =
             conn
             |> post_batch([
               start_operation("start", "2027-01-01"),
               open_operation("source", "guest", "ams-canal"),
               payment_operation("payment", "source", 100, "2027-01-02"),
               close_operation("close", "2027-01-10"),
               cancel_for_credit_operation("issue", "source", "2027-01-02")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "credit" => %{"movements" => %{"issued_cents" => 0}},
             "late_adjustments" => %{
               "credit" => %{"issued_cents" => 110, "expired_cents" => 0}
             }
           } = get_report("2027-01-11")

    assert %{
             "credit" => %{
               "movements" => %{"expired_cents" => 110},
               "closing_liability_cents" => 0
             },
             "late_adjustments" => %{
               "credit" => %{"issued_cents" => 0, "expired_cents" => 0}
             }
           } = get_report("2028-01-03")
  end

  test "posts retroactive credit application after the cutoff without changing the closed expiry",
       %{
         conn: conn
       } do
    assert %{"results" => setup_results} =
             conn
             |> post_batch([
               open_operation("source", "guest", "ams-canal"),
               payment_operation("payment", "source", 100, "2027-01-02"),
               cancel_for_credit_operation("issue", "source", "2027-01-02"),
               open_operation("target", "guest", "ams-canal"),
               start_operation("start", "2027-01-01"),
               close_operation("close", "2028-01-03")
             ])
             |> json_response(200)

    assert Enum.all?(setup_results, &(&1["status"] == "applied"))
    closed_report = get_report("2028-01-03")

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([
               apply_credit_operation("late-apply", "target", 110, "2027-06-01")
             ])
             |> json_response(200)

    assert get_report("2028-01-03") == closed_report

    assert get_report("2028-01-04") == %{
             "date" => "2028-01-04",
             "status" => "open",
             "cash" => [],
             "credit" => credit_report(0, %{}, 110),
             "late_adjustments" => late_adjustments([], %{"expired_cents" => -110})
           }
  end

  test "posts revocation and its expiry reversal after the cutoff", %{conn: conn} do
    assert %{"results" => setup_results} =
             conn
             |> post_batch([
               open_operation("source", "guest", "ams-canal"),
               payment_operation("payment", "source", 100, "2027-01-02"),
               cancel_for_credit_operation("issue", "source", "2027-01-02"),
               start_operation("start", "2027-01-01"),
               close_operation("close", "2028-01-03")
             ])
             |> json_response(200)

    assert Enum.all?(setup_results, &(&1["status"] == "applied"))
    closed_report = get_report("2028-01-03")

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([chargeback_operation("chargeback", "payment", "2027-06-01")])
             |> json_response(200)

    assert get_report("2028-01-03") == closed_report

    assert get_report("2028-01-04") == %{
             "date" => "2028-01-04",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments(
                 [
                   %{
                     "property_id" => "ams-canal",
                     "movements" =>
                       cash_movements(%{
                         "converted_to_credit_cents" => -100,
                         "charged_back_cents" => 100
                       })
                   }
                 ],
                 %{"expired_cents" => -110, "revoked_cents" => 110}
               )
           }
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp start_operation(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
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

  defp open_operation(group_id, guest_id, property_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2029-12-10",
      "departure_on" => "2029-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
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

  defp cancel_operation(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp cancel_for_credit_operation(operation_id, group_id, occurred_on) do
    cancel_operation(operation_id, group_id, occurred_on)
    |> Map.put("refund_method", "hotel_credit")
  end

  defp apply_credit_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp cash_movements(overrides \\ %{}) do
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

  defp credit_movements(overrides) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end

  defp credit_report(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movements),
      "closing_liability_cents" => closing
    }
  end

  defp late_adjustments(cash \\ [], credit \\ %{}) do
    %{"cash" => cash, "credit" => credit_movements(credit)}
  end
end
