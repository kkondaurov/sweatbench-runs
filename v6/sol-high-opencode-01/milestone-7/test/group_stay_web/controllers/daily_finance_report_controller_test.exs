defmodule GroupStayWeb.DailyFinanceReportControllerTest do
  use GroupStayWeb.ConnCase

  test "validates and durably starts reporting once", %{conn: conn} do
    invalid = %{
      "operation_id" => "invalid-start",
      "type" => "start_finance_reporting"
    }

    start = start_operation("start", "2027-01-10")

    assert %{"results" => [invalid_result, started, already_started, replayed]} =
             conn
             |> post_batch([
               invalid,
               start,
               start_operation("other-start", "2027-01-11"),
               start
             ])
             |> json_response(200)

    assert invalid_result["code"] == "invalid_reporting_date"

    assert started == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-10"
           }

    assert already_started["code"] == "reporting_already_started"
    assert replayed == started

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             build_conn()
             |> get("/api/v1/finance/daily-report")
             |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             build_conn()
             |> get("/api/v1/finance/daily-report?date=2027-01-09")
             |> json_response(404)
  end

  test "captures preceding operations as opening and clamps following movements", %{conn: conn} do
    operations = [
      open_operation("group", "guest", "ams-canal"),
      payment_operation("opening-payment", "group", 100, "2028-01-01"),
      start_operation("start", "2027-01-10"),
      payment_operation("reported-payment", "group", 50, "2027-01-01")
    ]

    assert %{"results" => [_, _, _, %{"status" => "applied"}]} =
             conn |> post_batch(operations) |> json_response(200)

    assert %{
             "date" => "2027-01-10",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 100,
                 "movements" => %{
                   "received_cents" => 50,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 150
               }
             ],
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
           } = get_report("2027-01-10")
  end

  test "attributes transfers and corrections to the affected properties", %{conn: conn} do
    operations = [
      start_operation("start", "2027-01-10"),
      open_operation("source", "guest", "ams-canal"),
      open_operation("destination", "guest", "ber-river"),
      payment_operation("payment", "source", 300),
      transfer_operation("transfer", "source", "destination", 100),
      reduce_operation("reduce", "payment", 50),
      cancel_operation("refund", "destination"),
      chargeback_operation("chargeback", "payment")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"cash" => [ams, ber]} = get_report("2027-01-10")

    assert ams == %{
             "property_id" => "ams-canal",
             "opening_held_cents" => 0,
             "movements" => %{
               "received_cents" => 300,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 100,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 200
             },
             "closing_held_cents" => 0
           }

    assert ber == %{
             "property_id" => "ber-river",
             "opening_held_cents" => 0,
             "movements" => %{
               "received_cents" => 0,
               "transferred_in_cents" => 100,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 50,
               "charged_back_cents" => 50
             },
             "closing_held_cents" => 0
           }
  end

  test "reports automatic expiry while applied credit remains liable", %{conn: conn} do
    operations = [
      start_operation("start", "2027-01-01"),
      open_operation("source", "guest", "ams-canal"),
      payment_operation("payment", "source", 100, "2027-01-02"),
      cancel_operation("issue", "source", %{
        "occurred_on" => "2027-01-02",
        "refund_method" => "hotel_credit"
      }),
      open_operation("target", "guest", "ams-canal"),
      apply_credit_operation("apply", "target", 40, "2027-01-03")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "opening_liability_cents" => 110,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 70,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 40
           } = get_report("2028-01-03")["credit"]

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([
               cancel_operation("restore-expired", "target", %{"occurred_on" => "2028-01-04"})
             ])
             |> json_response(200)

    first = get_report("2028-01-04")
    second = get_report("2028-01-04")
    assert first == second

    assert first["credit"] == %{
             "opening_liability_cents" => 40,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 40,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end

  test "distinguishes available-credit revocation from later shortfall absorption", %{conn: conn} do
    operations = [
      start_operation("start", "2027-01-01"),
      open_operation("source", "guest", "ams-canal"),
      payment_operation("payment", "source", 100, "2027-01-02"),
      cancel_operation("issue", "source", %{
        "occurred_on" => "2027-01-02",
        "refund_method" => "hotel_credit"
      }),
      open_operation("target", "guest", "ams-canal"),
      apply_credit_operation("apply", "target", 40, "2027-01-03"),
      Map.put(chargeback_operation("chargeback", "payment"), "occurred_on", "2027-01-04")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "opening_liability_cents" => 110,
             "movements" => %{"revoked_cents" => 70},
             "closing_liability_cents" => 40
           } = get_report("2027-01-04")["credit"]

    assert %{"results" => [%{"status" => "applied"}]} =
             build_conn()
             |> post_batch([
               cancel_operation("absorb", "target", %{"occurred_on" => "2027-01-05"})
             ])
             |> json_response(200)

    assert %{
             "opening_liability_cents" => 40,
             "movements" => %{"absorbed_cents" => 40},
             "closing_liability_cents" => 0
           } = get_report("2027-01-05")["credit"]
  end

  test "retroactive application reverses pre-inception expiry on the clamped posting date", %{
    conn: conn
  } do
    operations = [
      open_operation("source", "guest", "ams-canal"),
      payment_operation("payment", "source", 100, "2027-01-02"),
      cancel_operation("issue", "source", %{
        "occurred_on" => "2027-01-02",
        "refund_method" => "hotel_credit"
      }),
      open_operation("target", "guest", "ams-canal"),
      start_operation("start", "2029-01-01"),
      apply_credit_operation("late-apply", "target", 110, "2027-06-01")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "opening_liability_cents" => 0,
             "movements" => %{"expired_cents" => -110},
             "closing_liability_cents" => 110
           } = get_report("2029-01-01")["credit"]

    assert %{"data" => %{"credit_liability_cents" => 110}} =
             build_conn()
             |> get("/api/v1/ledger?on=2029-01-01")
             |> json_response(200)
  end

  test "clamped chargeback reports revocation instead of expiry", %{conn: conn} do
    operations = [
      open_operation("source", "guest", "ams-canal"),
      payment_operation("payment", "source", 100, "2027-01-02"),
      start_operation("start", "2029-01-01"),
      cancel_operation("issue", "source", %{
        "occurred_on" => "2027-01-02",
        "refund_method" => "hotel_credit"
      }),
      Map.put(chargeback_operation("chargeback", "payment"), "occurred_on", "2027-06-01")
    ]

    assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 110,
               "expired_cents" => 0,
               "revoked_cents" => 110
             },
             "closing_liability_cents" => 0
           } = get_report("2029-01-01")["credit"]
  end

  test "accepts expanded ISO years used by credit expiration dates", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             conn
             |> post_batch([start_operation("start", "10000-01-01")])
             |> json_response(200)

    assert %{"date" => "10000-01-02", "status" => "open"} = get_report("10000-01-02")
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

  defp payment_operation(operation_id, group_id, amount, occurred_on \\ "2027-01-10") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer_operation(operation_id, source, destination, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-10",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp reduce_operation(operation_id, payment_operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-10",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-10",
      "payment_operation_id" => payment_operation_id
    }
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

  defp cancel_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2027-01-10",
        "group_id" => group_id
      },
      overrides
    )
  end
end
