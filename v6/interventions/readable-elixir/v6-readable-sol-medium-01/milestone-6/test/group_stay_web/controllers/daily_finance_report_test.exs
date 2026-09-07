defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  describe "reporting inception and reads" do
    test "validates dates and makes the first start durable", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/finance/daily-report"), 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert json_response(get(conn, ~p"/api/v1/finance/daily-report?date=nope"), 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert json_response(get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-01"), 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      operations = [
        %{"operation_id" => "invalid", "type" => "start_finance_reporting"},
        start("start", "2027-01-02"),
        start("another", "2027-01-03"),
        start("start", "2027-01-02")
      ]

      conn = post(recycle(conn), ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [invalid, started, duplicate, replay]} = json_response(conn, 200)
      assert invalid["code"] == "invalid_reporting_date"

      assert started == %{
               "operation_id" => "start",
               "status" => "applied",
               "starts_on" => "2027-01-02"
             }

      assert duplicate["code"] == "reporting_already_started"
      assert replay == started

      assert json_response(
               get(recycle(conn), ~p"/api/v1/finance/daily-report?date=2027-01-01"),
               404
             ) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "captures prior and same-batch state as opening and floors later posting dates", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("before", "guest", "alpha", "2027-03-01"),
            cash("before-pay", "before", 1_000, "2027-03-02"),
            start("start", "2027-01-10"),
            open("after", "guest", "beta", "2027-01-01"),
            cash("after-pay", "after", 500, "2027-01-02")
          ]
        })

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      report = report(conn, "2027-01-10")
      assert report["status"] == "open"

      assert report["cash"] == [
               cash_entry("alpha", 1_000, %{}, 1_000),
               cash_entry("beta", 0, %{"received_cents" => 500}, 500)
             ]

      assert report["credit"] == credit_entry(0, %{}, 0)

      assert report(conn, "2027-01-11")["cash"] |> Enum.at(1) |> Map.fetch!("opening_held_cents") ==
               500
    end
  end

  describe "cash movement classifications" do
    test "reports transfers, settlement reversals, reductions, and chargebacks by property", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            start("start", "2026-10-01"),
            open("source", "guest", "alpha", "2026-10-01"),
            open("destination", "guest", "beta", "2026-10-01"),
            cash("pay", "source", 1_000, "2026-10-02"),
            transfer("move", "source", "destination", 700, "2026-10-03"),
            reduce("reduce", "pay", 200, "2026-10-04"),
            cancel("refund", "destination", "2026-10-05"),
            chargeback("chargeback", "pay", "2026-10-06")
          ]
        })

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      assert report(conn, "2026-10-03")["cash"] == [
               cash_entry("alpha", 1_000, %{"transferred_out_cents" => 700}, 300),
               cash_entry("beta", 0, %{"transferred_in_cents" => 700}, 700)
             ]

      assert report(conn, "2026-10-04")["cash"] == [
               cash_entry("alpha", 300, %{}, 300),
               cash_entry("beta", 700, %{"reduced_cents" => 200}, 500)
             ]

      assert report(conn, "2026-10-05")["cash"] == [
               cash_entry("alpha", 300, %{}, 300),
               cash_entry("beta", 500, %{"refunded_cents" => 500}, 0)
             ]

      assert report(conn, "2026-10-06")["cash"] == [
               cash_entry("alpha", 300, %{"charged_back_cents" => 300}, 0),
               cash_entry(
                 "beta",
                 0,
                 %{"refunded_cents" => -500, "charged_back_cents" => 500},
                 0
               )
             ]
    end
  end

  describe "credit liability movements" do
    test "reports issue, paused expiry, restoration expiry, and shortfall absorption", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            start("start", "2026-01-01"),
            open("issuer", "guest", "alpha", "2026-01-01"),
            cash("pay", "issuer", 1_000, "2026-01-02"),
            cancel_to_credit("issue", "issuer", "2026-01-03"),
            open("target", "guest", "beta", "2026-01-04"),
            credit("apply", "target", 800, "2026-01-05")
          ]
        })

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      assert report(conn, "2026-01-03")["credit"] ==
               credit_entry(0, %{"issued_cents" => 1_100}, 1_100)

      # Only the unused 300 expires automatically; the 800 funding the target is paused.
      assert report(conn, "2027-01-04")["credit"] ==
               credit_entry(1_100, %{"expired_cents" => 300}, 800)

      conn =
        post(recycle(conn), ~p"/api/v1/partner-batches", %{
          operations: [cancel("restore-expired", "target", "2027-02-01")]
        })

      assert hd(json_response(conn, 200)["results"])["status"] == "applied"

      assert report(conn, "2027-02-01")["credit"] ==
               credit_entry(800, %{"expired_cents" => 800}, 0)
    end

    test "reports revocation without double-counting expiry", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            start("start", "2026-01-01"),
            open("issuer", "guest", "alpha", "2026-01-01"),
            cash("pay", "issuer", 1_000, "2026-01-02"),
            cancel_to_credit("issue", "issuer", "2026-01-03"),
            chargeback("chargeback", "pay", "2026-01-04")
          ]
        })

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      assert report(conn, "2026-01-04")["credit"] ==
               credit_entry(1_100, %{"revoked_cents" => 1_100}, 0)

      assert report(conn, "2027-01-04")["credit"] == credit_entry(0, %{}, 0)
    end

    test "reports credit consumed by a non-refundable settlement", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            start("start", "2026-01-01"),
            open("issuer", "guest", "alpha", "2026-01-01"),
            cash("pay", "issuer", 1_000, "2026-01-02"),
            cancel_to_credit("issue", "issuer", "2026-01-03"),
            advance_open("target", "guest", "beta", "2026-01-04"),
            credit("apply", "target", 500, "2026-01-05"),
            cancel("consume", "target", "2026-01-06")
          ]
        })

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      assert report(conn, "2026-01-06")["credit"] ==
               credit_entry(1_100, %{"consumed_cents" => 500}, 600)
    end

    test "keeps a clawed-back applied amount as liability until restoration absorbs it", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            start("start", "2026-01-01"),
            open("issuer", "guest", "alpha", "2026-01-01"),
            cash("pay", "issuer", 1_000, "2026-01-02"),
            cancel_to_credit("issue", "issuer", "2026-01-03"),
            open("target", "guest", "beta", "2026-01-04"),
            credit("apply", "target", 800, "2026-01-05"),
            chargeback("chargeback", "pay", "2026-01-06"),
            cancel("restore", "target", "2026-01-07")
          ]
        })

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      assert report(conn, "2026-01-06")["credit"] ==
               credit_entry(1_100, %{"revoked_cents" => 300}, 800)

      assert report(conn, "2026-01-07")["credit"] ==
               credit_entry(800, %{"absorbed_cents" => 800}, 0)
    end
  end

  defp report(conn, date) do
    conn
    |> recycle()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cash_entry(property_id, opening, overrides, closing) do
    movements = %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }

    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(movements, overrides),
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, overrides, closing) do
    movements = %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }

    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(movements, overrides),
      "closing_liability_cents" => closing
    }
  end

  defp start(id, date),
    do: %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => date}

  defp open(id, guest, property, occurred_on) do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => id,
      "guest_id" => guest,
      "property_id" => property,
      "arrival_on" => "2028-06-01",
      "departure_on" => "2028-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp advance_open(id, guest, property, occurred_on),
    do: Map.put(open(id, guest, property, occurred_on), "rate_plan", "advance_purchase")

  defp cash(id, group, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp credit(id, group, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp transfer(id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp reduce(id, payment, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment,
      "amount_cents" => amount
    }
  end

  defp chargeback(id, payment, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment
    }
  end

  defp cancel(id, group, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group
    }
  end

  defp cancel_to_credit(id, group, occurred_on),
    do: Map.put(cancel(id, group, occurred_on), "refund_method", "hotel_credit")
end
