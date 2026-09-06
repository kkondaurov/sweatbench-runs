defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "validates, advances, and durably replays finance closes", %{conn: conn} do
    before_start = close_operation("before-start", "2026-10-01")
    %{"results" => [rejected]} = post_batch(conn, [before_start])
    assert rejected["code"] == "invalid_period"

    operations = [
      start_operation("start", "2026-10-01"),
      close_operation("before-inception", "2026-09-30"),
      close_operation("malformed", "not-a-date"),
      %{close_operation("bad-occurred", "2026-10-01") | "occurred_on" => "not-a-date"},
      close_operation("close-one", "2026-10-01")
    ]

    %{"results" => [started, too_early, malformed, bad_occurred, closed]} =
      post_batch(build_conn(), operations)

    assert started["status"] == "applied"
    assert too_early["code"] == "invalid_period"
    assert malformed["code"] == "invalid_period"
    assert bad_occurred["code"] == "invalid_operation"

    assert closed == %{
             "operation_id" => "close-one",
             "status" => "applied",
             "period_end_on" => "2026-10-01"
           }

    %{"results" => [old_replay, replay, conflict, duplicate, earlier, later]} =
      post_batch(build_conn(), [
        before_start,
        close_operation("close-one", "2026-10-01"),
        close_operation("close-one", "2026-10-02"),
        close_operation("duplicate", "2026-10-01"),
        close_operation("earlier", "2026-09-30"),
        close_operation("later", "2026-10-03")
      ])

    assert old_replay == rejected
    assert replay == closed
    assert conflict["code"] == "operation_id_conflict"
    assert duplicate["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"

    assert later == %{
             "operation_id" => "later",
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    assert get_report("2026-10-03")["status"] == "closed"
    assert get_report("2026-10-04")["status"] == "open"
  end

  test "closing a far-future cutoff does not require enumerating report dates", %{conn: conn} do
    %{"results" => [started, closed]} =
      post_batch(conn, [
        start_operation("start", "2026-10-01"),
        close_operation("close", "9999-12-31")
      ])

    assert started["status"] == "applied"
    assert closed["status"] == "applied"
    assert get_report("9999-12-31")["status"] == "closed"
  end

  test "same-batch operations see closes and split ordinary from late movements", %{conn: conn} do
    operations = [
      start_operation("start", "2026-10-01"),
      open_operation("group", "amsterdam", "guest", "2026-12-20"),
      payment_operation("before-close", "group", 100, "2026-10-02"),
      close_operation("close", "2026-10-02"),
      payment_operation("late", "group", 200, "2026-10-01"),
      payment_operation("ordinary", "group", 300, "2026-10-03")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    closed = get_report("2026-10-02")
    assert closed["status"] == "closed"
    assert hd(closed["cash"])["movements"] == cash_movements(%{"received_cents" => 100})
    assert closed["late_adjustments"] == late_adjustments()

    open = get_report("2026-10-03")

    assert open["cash"] == [
             %{
               "property_id" => "amsterdam",
               "opening_held_cents" => 100,
               "movements" => cash_movements(%{"received_cents" => 300}),
               "closing_held_cents" => 600
             }
           ]

    assert open["late_adjustments"] ==
             late_adjustments([
               %{
                 "property_id" => "amsterdam",
                 "movements" => cash_movements(%{"received_cents" => 200})
               }
             ])

    %{"results" => [next_close, next_late]} =
      post_batch(build_conn(), [
        close_operation("next-close", "2026-10-03"),
        payment_operation("next-late", "group", 50, "2026-10-01")
      ])

    assert next_close["status"] == "applied"
    assert next_late["status"] == "applied"
    assert get_report("2026-10-02") == closed
    assert get_report("2026-10-03") == %{open | "status" => "closed"}

    assert get_report("2026-10-04")["late_adjustments"]["cash"] == [
             %{
               "property_id" => "amsterdam",
               "movements" => cash_movements(%{"received_cents" => 50})
             }
           ]
  end

  test "late chargebacks retain signed settlement classifications", %{conn: conn} do
    operations = [
      start_operation("start", "2026-10-01"),
      open_operation("group", "amsterdam", "guest", "2026-12-20"),
      payment_operation("pay", "group", 100, "2026-10-02"),
      cancel_operation("cancel", "group", "2026-10-02"),
      close_operation("close", "2026-10-02"),
      chargeback_operation("chargeback", "pay", "2026-10-02")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    report = get_report("2026-10-03")
    assert hd(report["cash"])["opening_held_cents"] == 0
    assert hd(report["cash"])["closing_held_cents"] == 0

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "amsterdam",
               "movements" =>
                 cash_movements(%{"refunded_cents" => -100, "charged_back_cents" => 100})
             }
           ]
  end

  test "late credit effects are separated and keep closed automatic expiry stable", %{conn: conn} do
    operations = [
      start_operation("start", "2026-01-01"),
      open_operation("source", "amsterdam", "guest", "2026-12-31"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit"),
      close_operation("close", "2027-01-03")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    expired_report = get_report("2027-01-03")
    assert expired_report["status"] == "closed"
    assert expired_report["credit"] == credit(110, %{"expired_cents" => 110}, 0)

    late_application = [
      open_operation("target", "amsterdam", "guest", "2028-01-01"),
      credit_operation("late-application", "target", 50, "2026-01-03")
    ]

    %{"results" => late_results} = post_batch(build_conn(), late_application)
    assert Enum.all?(late_results, &(&1["status"] == "applied"))
    assert get_report("2027-01-03") == expired_report

    first_open = get_report("2027-01-04")
    assert first_open["credit"] == credit(0, %{}, 50)

    assert first_open["late_adjustments"]["credit"] ==
             credit_movements(%{"expired_cents" => -50})
  end

  test "late credit issuance is reported on the first open day", %{conn: conn} do
    operations = [
      start_operation("start", "2026-01-01"),
      open_operation("source", "amsterdam", "guest", "2026-12-31"),
      close_operation("close", "2026-01-02"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    report = get_report("2026-01-03")
    assert report["credit"] == credit(0, %{}, 110)
    assert report["late_adjustments"]["credit"] == credit_movements(%{"issued_cents" => 110})

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "amsterdam",
               "movements" =>
                 cash_movements(%{
                   "received_cents" => 100,
                   "converted_to_credit_cents" => 100
                 })
             }
           ]
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
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
      "occurred_on" => starts_on,
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "occurred_on" => "2026-10-01",
      "period_end_on" => period_end_on
    }
  end

  defp open_operation(group_id, property_id, guest_id, arrival_on) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => arrival_on,
      "departure_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 1)),
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

  defp credit_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp chargeback_operation(operation_id, payment_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }
  end

  defp late_adjustments(cash \\ []) do
    %{"cash" => cash, "credit" => credit_movements()}
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

  defp credit_movements(overrides \\ %{}) do
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

  defp credit(opening, movement_overrides, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movement_overrides),
      "closing_liability_cents" => closing
    }
  end
end
