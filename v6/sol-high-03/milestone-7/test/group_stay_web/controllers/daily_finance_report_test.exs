defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  describe "starting and reading finance reporting" do
    test "freezes the mid-batch opening, clamps later postings, and replays durably", %{
      conn: conn
    } do
      start = %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-02-01",
        "expected_revision" => 999
      }

      operations = [
        open_operation("open-inception", "inception", "zrh-center"),
        payment_operation("opening-payment", "inception", 60, "2027-03-01"),
        start,
        payment_operation("clamped-payment", "inception", 20, "2027-01-15")
      ]

      assert %{"results" => [_, _, started, paid]} =
               conn |> post_batch(operations) |> json_response(200)

      assert started == %{
               "operation_id" => "start-reporting",
               "status" => "applied",
               "starts_on" => "2027-02-01"
             }

      assert paid["status"] == "applied"

      assert %{
               "data" => %{
                 "date" => "2027-02-01",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "zrh-center",
                     "opening_held_cents" => 60,
                     "movements" => %{
                       "received_cents" => 20,
                       "transferred_in_cents" => 0,
                       "transferred_out_cents" => 0,
                       "refunded_cents" => 0,
                       "retained_cents" => 0,
                       "converted_to_credit_cents" => 0,
                       "reduced_cents" => 0,
                       "charged_back_cents" => 0
                     },
                     "closing_held_cents" => 80
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
               }
             } = get_report("2027-02-01")

      assert build_conn() |> post_batch([start]) |> json_response(200) == %{
               "results" => [started]
             }

      assert get_report("2027-02-01")
             |> get_in(["data", "cash", Access.at(0), "closing_held_cents"]) == 80

      assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
               build_conn()
               |> post_batch([
                 %{"operation_id" => "invalid-second-start", "type" => "start_finance_reporting"}
               ])
               |> json_response(200)

      assert %{"results" => [%{"code" => "reporting_already_started"}]} =
               build_conn()
               |> post_batch([
                 %{
                   "operation_id" => "second-start",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2027-02-02"
                 }
               ])
               |> json_response(200)
    end

    test "validates report dates and availability without changing state", %{conn: conn} do
      for path <- [
            "/api/v1/finance/daily-report",
            "/api/v1/finance/daily-report?date=",
            "/api/v1/finance/daily-report?date=not-a-date",
            "/api/v1/finance/daily-report?date=2027-02-30"
          ] do
        assert conn |> recycle() |> get(path) |> json_response(422) == %{
                 "error" => %{"code" => "invalid_reporting_date"}
               }
      end

      assert get(build_conn(), "/api/v1/finance/daily-report?date=2027-02-01")
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      start_reporting("2027-02-02")

      assert get(build_conn(), "/api/v1/finance/daily-report?date=2027-02-01")
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      before = get_ledger("2027-02-03")
      first = get_report("2027-02-03")
      assert first == get_report("2027-02-03")
      assert before == get_ledger("2027-02-03")
      assert first["data"]["cash"] == []
    end

    test "captures pre-start credit as opening liability and preserves its passive expiry", %{
      conn: conn
    } do
      operations = [
        open_operation("open-before-start", "before-start", "ams-canal", "flexible", 500),
        payment_operation("pay-before-start", "before-start", 100, "2027-01-01"),
        cancel_operation("credit-before-start", "before-start", "2027-01-02", "hotel_credit"),
        start_operation("2027-01-01")
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      opening = get_report("2027-01-01")["data"]["credit"]
      assert opening["opening_liability_cents"] == 110
      assert opening["movements"]["issued_cents"] == 0
      assert opening["closing_liability_cents"] == 110

      expiry = get_report("2028-01-03")["data"]["credit"]
      assert expiry["opening_liability_cents"] == 110
      assert expiry["movements"]["expired_cents"] == 110
      assert expiry["closing_liability_cents"] == 0
    end

    test "keeps inception aggregates beyond SQLite int64 in application arithmetic", %{conn: conn} do
      max = 9_223_372_036_854_775_807

      operations = [
        open_operation("open-huge-a", "huge-a", "huge-property", "advance_purchase", max),
        payment_operation("pay-huge-a", "huge-a", max, "2027-01-01"),
        open_operation("open-huge-b", "huge-b", "huge-property", "advance_purchase", max),
        payment_operation("pay-huge-b", "huge-b", max, "2027-01-01"),
        start_operation("2027-01-01")
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert [entry] = get_report("2027-01-01")["data"]["cash"]
      assert entry["opening_held_cents"] == 2 * max
      assert entry["closing_held_cents"] == 2 * max
    end
  end

  describe "cash movements by property" do
    test "tracks transfers and later corrections where the cash is held", %{conn: conn} do
      operations = [
        start_operation("2027-02-01"),
        open_operation("open-source", "source", "ams-canal"),
        open_operation("open-destination", "destination", "ber-mitte"),
        payment_operation("payment", "source", 100, "2027-02-01"),
        transfer_operation("transfer", "source", "destination", 60, "2027-02-02"),
        %{
          "operation_id" => "reduction",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-02-03",
          "payment_operation_id" => "payment",
          "amount_cents" => 20
        },
        %{
          "operation_id" => "chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-02-04",
          "payment_operation_id" => "payment"
        }
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert [ams, berlin] = get_report("2027-02-02")["data"]["cash"]
      assert ams["property_id"] == "ams-canal"
      assert ams["opening_held_cents"] == 100
      assert ams["movements"]["transferred_out_cents"] == 60
      assert ams["closing_held_cents"] == 40
      assert berlin["property_id"] == "ber-mitte"
      assert berlin["movements"]["transferred_in_cents"] == 60
      assert berlin["closing_held_cents"] == 60

      assert [_ams_unchanged, berlin_reduction] =
               get_report("2027-02-03")["data"]["cash"]

      assert berlin_reduction["property_id"] == "ber-mitte"
      assert berlin_reduction["opening_held_cents"] == 60
      assert berlin_reduction["movements"]["reduced_cents"] == 20
      assert berlin_reduction["closing_held_cents"] == 40

      assert [ams_chargeback, berlin_chargeback] = get_report("2027-02-04")["data"]["cash"]
      assert ams_chargeback["movements"]["charged_back_cents"] == 40
      assert ams_chargeback["closing_held_cents"] == 0
      assert berlin_chargeback["movements"]["charged_back_cents"] == 40
      assert berlin_chargeback["closing_held_cents"] == 0

      assert get_ledger("2027-02-04")["data"]["cash_held_cents"] == 0
    end

    test "keeps same-property transfer columns even though held cash nets to zero", %{conn: conn} do
      operations = [
        start_operation("2027-02-01"),
        open_operation("open-same-source", "same-source", "ams-canal"),
        open_operation("open-same-destination", "same-destination", "ams-canal"),
        payment_operation("same-payment", "same-source", 50, "2027-02-01"),
        transfer_operation(
          "same-transfer",
          "same-source",
          "same-destination",
          50,
          "2027-02-02"
        )
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert [entry] = get_report("2027-02-02")["data"]["cash"]
      assert entry["opening_held_cents"] == 50
      assert entry["movements"]["transferred_in_cents"] == 50
      assert entry["movements"]["transferred_out_cents"] == 50
      assert entry["closing_held_cents"] == 50
    end
  end

  describe "hotel-credit liability movements" do
    test "reports available revocation and later shortfall absorption", %{conn: conn} do
      operations = [
        start_operation("2027-01-01"),
        open_operation("open-credit-source", "credit-source", "ams-canal", "flexible", 500),
        payment_operation("credit-payment", "credit-source", 100, "2027-01-01"),
        cancel_operation("issue-credit", "credit-source", "2027-01-02", "hotel_credit"),
        open_operation("open-credit-target", "credit-target", "ber-mitte", "flexible", 500),
        credit_operation("apply-some-credit", "credit-target", 60, "2027-01-03"),
        %{
          "operation_id" => "credit-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-04",
          "payment_operation_id" => "credit-payment"
        },
        cancel_operation("absorb-shortfall", "credit-target", "2027-01-05")
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      chargeback_report = get_report("2027-01-04")["data"]
      assert chargeback_report["credit"]["opening_liability_cents"] == 110
      assert chargeback_report["credit"]["movements"]["revoked_cents"] == 50
      assert chargeback_report["credit"]["closing_liability_cents"] == 60

      assert [cash] = chargeback_report["cash"]
      assert cash["opening_held_cents"] == 0
      assert cash["movements"]["converted_to_credit_cents"] == -100
      assert cash["movements"]["charged_back_cents"] == 100
      assert cash["closing_held_cents"] == 0

      absorption = get_report("2027-01-05")["data"]["credit"]
      assert absorption["opening_liability_cents"] == 60
      assert absorption["movements"]["absorbed_cents"] == 60
      assert absorption["closing_liability_cents"] == 0
    end

    test "posts passive expiry, expired restoration, and nonrefundable consumption", %{conn: conn} do
      advance =
        open_operation(
          "open-advance-target",
          "advance-target",
          "cph-center",
          "advance_purchase",
          100
        )

      operations = [
        start_operation("2027-01-01"),
        open_operation("open-expiry-source", "expiry-source", "ams-canal", "flexible", 500),
        payment_operation("expiry-payment", "expiry-source", 100, "2027-01-01"),
        cancel_operation("expiring-credit", "expiry-source", "2027-01-02", "hotel_credit"),
        open_operation("open-flex-target", "flex-target", "ber-mitte", "flexible", 500),
        advance,
        credit_operation("apply-flex", "flex-target", 40, "2027-01-03"),
        credit_operation("apply-advance", "advance-target", 30, "2027-01-03")
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      expiry = get_report("2028-01-03")["data"]["credit"]
      assert expiry["opening_liability_cents"] == 110
      assert expiry["movements"]["expired_cents"] == 40
      assert expiry["closing_liability_cents"] == 70

      assert %{"results" => [%{"status" => "applied"}]} =
               build_conn()
               |> post_batch([cancel_operation("restore-expired", "flex-target", "2028-01-04")])
               |> json_response(200)

      restored = get_report("2028-01-04")["data"]["credit"]
      assert restored["opening_liability_cents"] == 70
      assert restored["movements"]["expired_cents"] == 40
      assert restored["closing_liability_cents"] == 30

      assert %{"results" => [%{"status" => "applied"}]} =
               build_conn()
               |> post_batch([cancel_operation("consume-credit", "advance-target", "2028-01-05")])
               |> json_response(200)

      consumed = get_report("2028-01-05")["data"]["credit"]
      assert consumed["opening_liability_cents"] == 30
      assert consumed["movements"]["consumed_cents"] == 30
      assert consumed["closing_liability_cents"] == 0
      assert get_ledger("2028-01-05")["data"]["credit_liability_cents"] == 0
    end

    test "does not relabel already expired credit as revoked by a later chargeback", %{conn: conn} do
      operations = [
        start_operation("2027-01-01"),
        open_operation("open-expired-source", "expired-source", "ams-canal", "flexible", 500),
        payment_operation("expired-payment", "expired-source", 100, "2027-01-01"),
        cancel_operation("expired-lot", "expired-source", "2027-01-02", "hotel_credit")
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert get_report("2028-01-03")["data"]["credit"]["movements"]["expired_cents"] ==
               110

      chargeback = %{
        "operation_id" => "chargeback-expired-credit",
        "type" => "charge_back_payment",
        "occurred_on" => "2028-01-04",
        "payment_operation_id" => "expired-payment"
      }

      assert %{"results" => [%{"status" => "applied"}]} =
               build_conn() |> post_batch([chargeback]) |> json_response(200)

      assert get_report("2028-01-03")["data"]["credit"]["movements"]["expired_cents"] ==
               110

      credit = get_report("2028-01-04")["data"]["credit"]
      assert credit["opening_liability_cents"] == 0
      assert credit["movements"]["revoked_cents"] == 0
      assert credit["closing_liability_cents"] == 0
    end

    test "reconciles a pre-inception expiry reversed by a clamped credit application", %{
      conn: conn
    } do
      operations = [
        open_operation("open-clamped-source", "clamped-source", "ams-canal", "flexible", 500),
        payment_operation("clamped-payment", "clamped-source", 100, "2027-01-01"),
        cancel_operation("clamped-lot", "clamped-source", "2027-01-01", "hotel_credit"),
        open_operation("open-clamped-target", "clamped-target", "ber-mitte", "flexible", 500),
        start_operation("2028-02-01"),
        credit_operation("clamped-application", "clamped-target", 60, "2027-12-31")
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      credit = get_report("2028-02-01")["data"]["credit"]
      assert credit["opening_liability_cents"] == 0
      assert credit["movements"]["expired_cents"] == -60
      assert credit["closing_liability_cents"] == 60
      assert get_ledger("2028-02-01")["data"]["credit_liability_cents"] == 60
    end
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp get_report(date),
    do:
      build_conn()
      |> get("/api/v1/finance/daily-report?date=#{date}")
      |> json_response(200)

  defp get_ledger(date),
    do: build_conn() |> get("/api/v1/ledger?on=#{date}") |> json_response(200)

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

  defp open_operation(operation_id, group_id, property_id, rate_plan \\ "flexible", rate \\ 1_000) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "finance-guest",
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

  defp transfer_operation(operation_id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
