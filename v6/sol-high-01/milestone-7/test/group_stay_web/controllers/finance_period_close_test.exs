defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates closes and durably replays their exact results", %{conn: conn} do
    before_start = close("before-start", "2027-01-01")

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             post_batch(conn, [before_start])

    operations = [
      start("2027-01-05"),
      %{"operation_id" => "missing-cutoff", "type" => "close_finance_period"},
      close("bad-cutoff", "not-a-date"),
      close("too-early", "2027-01-04"),
      Map.put(close("first-close", "2027-01-05"), "expected_revision", 999),
      close("same-cutoff", "2027-01-05"),
      close("earlier-cutoff", "2027-01-04"),
      close("later-close", "2027-01-07")
    ]

    assert %{"results" => results} = post_batch(build_conn(), operations)

    assert Enum.at(results, 4) == %{
             "operation_id" => "first-close",
             "status" => "applied",
             "period_end_on" => "2027-01-05"
           }

    assert Enum.at(results, 7) == %{
             "operation_id" => "later-close",
             "status" => "applied",
             "period_end_on" => "2027-01-07"
           }

    for index <- [1, 2, 3, 5, 6] do
      assert Enum.at(results, index)["code"] == "invalid_period"
    end

    original = Enum.at(operations, 4)
    assert %{"results" => [replayed]} = post_batch(build_conn(), [original])
    assert replayed == Enum.at(results, 4)

    changed = Map.put(original, "period_end_on", "2027-01-06")

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             post_batch(build_conn(), [changed])

    assert build_conn()
           |> get(~p"/api/v1/operations/first-close")
           |> json_response(200) == %{"data" => replayed}
  end

  test "uses the in-batch close boundary and never moves a committed posting again", %{conn: conn} do
    assert_all_applied(post_batch(conn, [start("2027-01-01"), open("group", "property", 2_000)]))

    operations = [
      payment("before-close", "group", "2027-01-02", 100),
      close("close-through-two", "2027-01-02"),
      payment("after-close", "group", "2027-01-01", 100),
      payment("already-open-dated", "group", "2027-01-03", 50)
    ]

    assert_all_applied(post_batch(build_conn(), operations))

    closed_body = report_body("2027-01-02")

    assert Jason.decode!(closed_body) == %{
             "data" => %{
               "date" => "2027-01-02",
               "status" => "closed",
               "cash" => [cash_entry("property", 0, %{"received_cents" => 100}, 100)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    report = report("2027-01-03")

    assert report["status"] == "open"

    assert report["cash"] ==
             [cash_entry("property", 100, %{"received_cents" => 50}, 250)]

    assert report["late_adjustments"] ==
             late_adjustments([
               %{
                 "property_id" => "property",
                 "movements" => cash_movements(%{"received_cents" => 100})
               }
             ])

    assert_all_applied(
      post_batch(build_conn(), [
        close("close-through-three", "2027-01-03"),
        payment("after-later-close", "group", "2027-01-01", 100)
      ])
    )

    assert report_body("2027-01-02") == closed_body
    assert report("2027-01-03")["status"] == "closed"

    fourth = report("2027-01-04")
    assert fourth["cash"] == [cash_entry("property", 250, %{}, 350)]
    assert hd(fourth["late_adjustments"]["cash"])["movements"]["received_cents"] == 100
  end

  test "keeps signed zero-net cash classifications as late adjustments", %{conn: conn} do
    operations = [
      start("2027-01-01"),
      open("refundable", "ams-canal", 500),
      payment("payment", "refundable", "2027-01-02", 100),
      operation("refund", "cancel_group", "2027-01-03", %{"group_id" => "refundable"}),
      close("close-refund", "2027-01-03"),
      operation("chargeback", "charge_back_payment", "2027-01-03", %{
        "payment_operation_id" => "payment"
      })
    ]

    assert_all_applied(post_batch(conn, operations))

    report = report("2027-01-04")

    assert report["cash"] == [cash_entry("ams-canal", 0, %{}, 0)]

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" =>
                 cash_movements(%{
                   "refunded_cents" => -100,
                   "charged_back_cents" => 100
                 })
             }
           ]
  end

  test "freezes a closed automatic expiry and reports its late reversal", %{conn: conn} do
    operations = [
      start("2027-01-01"),
      open("source", "source-property", 500),
      payment("payment", "source", "2027-01-02", 100),
      operation("issue", "cancel_group", "2027-01-02", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open("target", "target-property", 500),
      close("close-expiry", "2028-01-03")
    ]

    assert_all_applied(post_batch(conn, operations))

    closed_body = report_body("2028-01-03")
    closed = Jason.decode!(closed_body)["data"]
    assert closed["status"] == "closed"
    assert closed["credit"] == credit_report(110, %{"expired_cents" => 110}, 0)

    apply =
      operation("late-application", "apply_hotel_credit", "2028-01-02", %{
        "group_id" => "target",
        "amount_cents" => 50
      })

    assert_all_applied(post_batch(build_conn(), [apply]))
    assert report_body("2028-01-03") == closed_body

    next = report("2028-01-04")
    assert next["credit"] == credit_report(0, %{}, 50)
    assert next["late_adjustments"]["credit"] == credit_movements(%{"expired_cents" => -50})
  end

  defp start(starts_on) do
    %{
      "operation_id" => "start-#{starts_on}",
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

  defp open(group_id, property_id, nightly_rate) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2029-05-01",
      "departure_on" => "2029-05-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp payment(operation_id, group_id, occurred_on, amount) do
    operation(operation_id, "record_cash_payment", occurred_on, %{
      "group_id" => group_id,
      "amount_cents" => amount
    })
  end

  defp operation(operation_id, type, occurred_on, fields) do
    Map.merge(
      %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on},
      fields
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp assert_all_applied(%{"results" => results}) do
    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  defp report(date) do
    date |> report_body() |> Jason.decode!() |> Map.fetch!("data")
  end

  defp report_body(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> response(200)
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
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
