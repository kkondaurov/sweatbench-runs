defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp start(operation_id \\ "start", starts_on \\ "2026-12-01") do
    %{
      "operation_id" => operation_id,
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

  defp open(operation_id \\ "open", group_id \\ "group") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-10",
      "departure_on" => "2027-03-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment(operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => "group",
      "amount_cents" => amount
    }
  end

  test "validates closes and durably replays applied and rejected results", %{conn: conn} do
    rejected = %{
      "operation_id" => "close-before-start",
      "status" => "rejected",
      "code" => "invalid_period"
    }

    assert post_operations(conn, [close("close-before-start", "2026-12-01")]) == [rejected]

    post_operations(conn, [start()])

    assert post_operations(conn, [close("close-before-start", "2026-12-01")]) == [rejected]

    assert post_operations(conn, [close("before-inception", "2026-11-30")]) == [
             %{
               "operation_id" => "before-inception",
               "status" => "rejected",
               "code" => "invalid_period"
             }
           ]

    applied = %{
      "operation_id" => "close-one",
      "status" => "applied",
      "period_end_on" => "2026-12-01"
    }

    assert post_operations(conn, [close("close-one", "2026-12-01")]) == [applied]
    assert post_operations(conn, [close("close-one", "2026-12-01")]) == [applied]

    for {operation_id, period_end_on} <- [
          {"same-cutoff", "2026-12-01"},
          {"earlier-cutoff", "2026-11-30"}
        ] do
      assert post_operations(conn, [close(operation_id, period_end_on)]) == [
               %{
                 "operation_id" => operation_id,
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
    end

    assert post_operations(conn, [
             Map.delete(close("missing-date", "2026-12-02"), "period_end_on")
           ]) ==
             [
               %{
                 "operation_id" => "missing-date",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
  end

  test "same-batch close fixes reports and moves older later operations to the first open day", %{
    conn: conn
  } do
    results =
      post_operations(conn, [
        open(),
        start(),
        payment("before-close", 500, "2026-11-01"),
        close("close-one", "2026-12-01"),
        payment("after-close", 700, "2026-11-01"),
        payment("future", 300, "2026-12-03")
      ])

    assert Enum.at(results, 3) == %{
             "operation_id" => "close-one",
             "status" => "applied",
             "period_end_on" => "2026-12-01"
           }

    closed = report(conn, "2026-12-01")
    assert closed["status"] == "closed"
    assert get_in(closed, ["cash", Access.at(0), "movements", "received_cents"]) == 500
    assert closed["late_adjustments"]["cash"] == []

    first_open = report(conn, "2026-12-02")
    assert first_open["status"] == "open"
    assert get_in(first_open, ["cash", Access.at(0), "movements", "received_cents"]) == 0

    assert first_open["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => cash_movements(%{"received_cents" => 700})
             }
           ]

    future = report(conn, "2026-12-03")
    assert get_in(future, ["cash", Access.at(0), "movements", "received_cents"]) == 300
    assert future["late_adjustments"]["cash"] == []

    post_operations(conn, [close("close-two", "2026-12-02")])
    closed_first_open = report(conn, "2026-12-02")
    post_operations(conn, [payment("another-old-payment", 200, "2026-10-01")])

    assert report(conn, "2026-12-01") == closed
    assert report(conn, "2026-12-02") == closed_first_open
  end

  test "late corrections preserve signed zero-net classifications", %{conn: conn} do
    post_operations(conn, [
      open(),
      start(),
      payment("pay", 1_000, "2026-12-01"),
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group",
        "refund_method" => "hotel_credit"
      },
      close("close", "2026-12-01"),
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-01",
        "payment_operation_id" => "pay"
      }
    ])

    adjustment = report(conn, "2026-12-02")["late_adjustments"]

    assert adjustment["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" =>
                 cash_movements(%{
                   "converted_to_credit_cents" => -1_000,
                   "charged_back_cents" => 1_000
                 })
             }
           ]

    assert adjustment["credit"] == credit_movements(%{"revoked_cents" => 1_100})
  end

  test "late credit issuance keeps its naturally future expiration ordinary", %{conn: conn} do
    post_operations(conn, [
      open(),
      start(),
      close("close", "2026-12-01"),
      payment("pay", 1_000, "2026-11-01"),
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group",
        "refund_method" => "hotel_credit"
      }
    ])

    issuance = report(conn, "2026-12-02")
    assert issuance["credit"]["movements"] == credit_movements(%{})
    assert issuance["late_adjustments"]["credit"] == credit_movements(%{"issued_cents" => 1_100})

    expiration = report(conn, "2027-11-02")

    assert expiration["credit"]["movements"] ==
             credit_movements(%{"expired_cents" => 1_100})

    assert expiration["late_adjustments"]["credit"] == credit_movements(%{})
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
end
