defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, op) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => [op]})
    json = Jason.decode!(resp.resp_body)
    assert resp.status == 200, "unexpected batch failure: #{inspect(json)}"
    hd(json["results"])
  end

  defp submit_all(conn, operations) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    json = Jason.decode!(resp.resp_body)
    assert resp.status == 200, "unexpected batch failure: #{inspect(json)}"
    json["results"]
  end

  defp open(conn, group_id, opts \\ []) do
    arrival_on = Keyword.get(opts, :arrival_on, "2027-03-31")
    booked_on = Keyword.get(opts, :booked_on, "2027-01-01")

    rooms =
      Keyword.get(
        opts,
        :rooms,
        [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      )

    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => Keyword.get(opts, :property_id, "ams-canal"),
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => rooms
    })
  end

  defp pay(conn, group_id, amount_cents, opts) do
    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "pay-#{group_id}"),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2027-01-10"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp cancel(conn, group_id, occurred_on, opts) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    op =
      case Keyword.fetch(opts, :refund_method) do
        {:ok, method} -> Map.put(op, "refund_method", method)
        :error -> op
      end

    submit(conn, op)
  end

  defp apply_credit(conn, group_id, amount_cents, occurred_on, opts) do
    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "credit-#{group_id}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp transfer(conn, source, destination, amount_cents, opts) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "transfer-#{source}-#{destination}"),
      "type" => "transfer_deposit",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount_cents
    }

    op =
      case Keyword.fetch(opts, :occurred_on) do
        {:ok, occurred_on} -> Map.put(op, "occurred_on", occurred_on)
        :error -> op
      end

    submit(conn, op)
  end

  defp reduce(conn, payment_operation_id, amount_cents, opts) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "reduce-#{payment_operation_id}"),
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }

    op =
      case Keyword.fetch(opts, :occurred_on) do
        {:ok, occurred_on} -> Map.put(op, "occurred_on", occurred_on)
        :error -> op
      end

    submit(conn, op)
  end

  defp charge_back(conn, payment_operation_id, opts) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "chargeback-#{payment_operation_id}"),
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id
    }

    op =
      case Keyword.fetch(opts, :occurred_on) do
        {:ok, occurred_on} -> Map.put(op, "occurred_on", occurred_on)
        :error -> op
      end

    submit(conn, op)
  end

  defp start(conn, starts_on, operation_id \\ "start-1") do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    })
  end

  defp report(conn, date) do
    resp = get(conn, "/api/v1/finance/daily-report?date=#{date}")
    {resp, Jason.decode!(resp.resp_body)}
  end

  defp report_data(conn, date) do
    {resp, body} = report(conn, date)
    assert resp.status == 200, "unexpected report failure: #{inspect(body)}"
    body["data"]
  end

  defp ledger(conn, opts \\ "") do
    conn |> get("/api/v1/ledger#{opts}") |> json_response(200) |> Map.fetch!("data")
  end

  defp cash_entry(data, property_id) do
    Enum.find(data["cash"], &(&1["property_id"] == property_id))
  end

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

  describe "starting finance reporting" do
    test "returns exactly the applied result and replays durably", %{conn: conn} do
      result = start(conn, "2027-01-01", "start-1")

      assert result == %{
               "operation_id" => "start-1",
               "status" => "applied",
               "starts_on" => "2027-01-01"
             }

      assert start(conn, "2027-01-01", "start-1") == result

      assert conn |> get("/api/v1/operations/start-1") |> json_response(200) |> Map.fetch!("data") ==
               result
    end

    test "a different start operation is rejected once reporting has started", %{conn: conn} do
      start(conn, "2027-01-01", "start-1")

      assert start(conn, "2027-02-01", "start-2") == %{
               "operation_id" => "start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      # The original reporting setup is unchanged.
      assert report_data(conn, "2027-01-01")["status"] == "open"
    end

    test "rejects an invalid or missing starts_on", %{conn: conn} do
      assert submit(conn, %{
               "operation_id" => "start-bad",
               "type" => "start_finance_reporting",
               "starts_on" => "2027-02-30"
             }) == %{
               "operation_id" => "start-bad",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      assert submit(conn, %{
               "operation_id" => "start-missing",
               "type" => "start_finance_reporting"
             }) == %{
               "operation_id" => "start-missing",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      {resp, body} = report(conn, "2027-01-01")
      assert resp.status == 404
      assert body == %{"error" => %{"code" => "report_not_available"}}
    end

    test "returns operation_id_conflict when the same identifier carries a different payload",
         %{conn: conn} do
      start(conn, "2027-01-01", "start-1")

      assert submit(conn, %{
               "operation_id" => "start-1",
               "type" => "start_finance_reporting",
               "starts_on" => "2027-06-01"
             })["code"] == "operation_id_conflict"
    end
  end

  describe "reading the daily report" do
    test "returns 422 for a missing or invalid date and 404 before reporting", %{conn: conn} do
      {resp, body} = report(conn, "2027-01-01")
      assert resp.status == 404
      assert body == %{"error" => %{"code" => "report_not_available"}}

      resp = get(conn, "/api/v1/finance/daily-report")
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body) == %{"error" => %{"code" => "invalid_reporting_date"}}

      resp = get(conn, "/api/v1/finance/daily-report?date=not-a-date")
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "returns 404 for dates before starts_on", %{conn: conn} do
      start(conn, "2027-01-01")

      {resp, body} = report(conn, "2026-12-31")
      assert resp.status == 404
      assert body == %{"error" => %{"code" => "report_not_available"}}
    end

    test "reports the opening position as of starts_on", %{conn: conn} do
      open(conn, "group-81")

      # A payment committed before reporting contributes to the opening
      # position even though its occurred_on is after starts_on.
      pay(conn, "group-81", 10_000, operation_id: "pay-1", occurred_on: "2027-03-01")

      start(conn, "2027-01-01")

      data = report_data(conn, "2027-01-01")

      assert data["date"] == "2027-01-01"
      assert data["status"] == "open"

      assert data["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10_000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 10_000
               }
             ]

      assert data["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 0
             }
    end

    test "operations before the start contribute to the opening position and later ones move",
         %{conn: conn} do
      open(conn, "group-81")

      results =
        submit_all(conn, [
          %{
            "operation_id" => "pay-pre",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "amount_cents" => 3_000
          },
          %{
            "operation_id" => "start-1",
            "type" => "start_finance_reporting",
            "starts_on" => "2027-01-01"
          },
          %{
            "operation_id" => "pay-post",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-05",
            "group_id" => "group-81",
            "amount_cents" => 2_000
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]

      data = report_data(conn, "2027-01-01")

      assert data["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 3_000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 3_000
               }
             ]

      data = report_data(conn, "2027-01-05")

      assert data["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 3_000,
                 "movements" => %{zero_cash_movements() | "received_cents" => 2_000},
                 "closing_held_cents" => 5_000
               }
             ]
    end

    test "a backdated operation posts on starts_on and changes the earlier report", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      pay(conn, "group-81", 4_000, operation_id: "pay-back", occurred_on: "2026-12-20")

      data = report_data(conn, "2027-01-01")

      assert data["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_cash_movements() | "received_cents" => 4_000},
                 "closing_held_cents" => 4_000
               }
             ]
    end

    test "omits properties whose balances and movements are all zero and sorts by property_id",
         %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "g-alpha", property_id: "alpha-lodge", operation_id: "open-alpha")
      open(conn, "g-zeta", property_id: "zeta-lodge", operation_id: "open-zeta")

      pay(conn, "g-zeta", 2_000, operation_id: "pay-zeta", occurred_on: "2027-01-10")
      pay(conn, "g-alpha", 3_000, operation_id: "pay-alpha", occurred_on: "2027-01-10")

      data = report_data(conn, "2027-01-10")

      assert Enum.map(data["cash"], & &1["property_id"]) == ["alpha-lodge", "zeta-lodge"]

      assert cash_entry(data, "alpha-lodge")["opening_held_cents"] == 0
      assert cash_entry(data, "alpha-lodge")["closing_held_cents"] == 3_000
      assert cash_entry(data, "zeta-lodge")["closing_held_cents"] == 2_000
    end

    test "reads are pure: reading repeatedly or out of order never changes a report", %{
      conn: conn
    } do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      pay(conn, "group-81", 5_000, operation_id: "pay-1", occurred_on: "2027-03-01")
      pay(conn, "group-81", 5_000, operation_id: "pay-2", occurred_on: "2027-04-01")

      first = report_data(conn, "2027-03-01")
      report_data(conn, "2027-04-01")
      again = report_data(conn, "2027-03-01")
      report_data(conn, "2027-03-01")

      assert first == again
      assert first["cash"] |> hd() |> Map.fetch!("closing_held_cents") == 5_000

      assert report_data(conn, "2027-04-01")["cash"]
             |> hd()
             |> Map.fetch!("closing_held_cents") == 10_000
    end
  end

  describe "cash movements" do
    test "reports refunded and retained settlements", %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "g-ref", arrival_on: "2027-03-31", booked_on: "2027-01-01")
      pay(conn, "g-ref", 6_000, operation_id: "pay-ref", occurred_on: "2027-01-10")
      cancel(conn, "g-ref", "2027-02-20", operation_id: "cancel-ref")

      open(conn, "g-ret", rate_plan: "advance_purchase", arrival_on: "2027-04-30")
      pay(conn, "g-ret", 6_000, operation_id: "pay-ret", occurred_on: "2027-02-25")
      cancel(conn, "g-ret", "2027-03-01", operation_id: "cancel-ret")

      data = report_data(conn, "2027-02-20")

      assert cash_entry(data, "ams-canal")["movements"] == %{
               zero_cash_movements()
               | "refunded_cents" => 6_000
             }

      assert cash_entry(data, "ams-canal")["closing_held_cents"] == 0

      data = report_data(conn, "2027-03-01")

      assert cash_entry(data, "ams-canal")["movements"] == %{
               zero_cash_movements()
               | "retained_cents" => 6_000
             }

      assert cash_entry(data, "ams-canal")["closing_held_cents"] == 0

      assert data["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 0
             }
    end

    test "reports conversion to credit and the issued liability", %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "g-conv", arrival_on: "2027-03-31")
      pay(conn, "g-conv", 6_000, operation_id: "pay-conv", occurred_on: "2027-01-10")

      cancel(conn, "g-conv", "2027-02-20",
        operation_id: "cancel-conv",
        refund_method: "hotel_credit"
      )

      data = report_data(conn, "2027-02-20")

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 6_000,
               "movements" => %{zero_cash_movements() | "converted_to_credit_cents" => 6_000},
               "closing_held_cents" => 0
             }

      assert data["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{zero_credit_movements() | "issued_cents" => 6_600},
               "closing_liability_cents" => 6_600
             }

      assert ledger(conn, "?on=2027-02-20")["credit_liability_cents"] == 6_600
    end

    test "transfers move held cash between the source and destination properties", %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "x-src", property_id: "ams-canal", operation_id: "open-x-src")
      open(conn, "x-dst", property_id: "rot-park", operation_id: "open-x-dst")

      pay(conn, "x-src", 8_000, operation_id: "pay-x", occurred_on: "2027-01-10")

      transfer(conn, "x-src", "x-dst", 3_000,
        operation_id: "x-transfer",
        occurred_on: "2027-01-15"
      )

      data = report_data(conn, "2027-01-15")

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 8_000,
               "movements" => %{zero_cash_movements() | "transferred_out_cents" => 3_000},
               "closing_held_cents" => 5_000
             }

      assert cash_entry(data, "rot-park") == %{
               "property_id" => "rot-park",
               "opening_held_cents" => 0,
               "movements" => %{zero_cash_movements() | "transferred_in_cents" => 3_000},
               "closing_held_cents" => 3_000
             }

      # Transferred-in and transferred-out are equal across all properties.
      assert Enum.sum(Enum.map(data["cash"], & &1["movements"]["transferred_in_cents"])) ==
               Enum.sum(Enum.map(data["cash"], & &1["movements"]["transferred_out_cents"]))
    end

    test "reductions follow the affected cash to the properties holding it", %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "r-src", property_id: "ams-canal", operation_id: "open-r-src")
      open(conn, "r-dst", property_id: "rot-park", operation_id: "open-r-dst")

      pay(conn, "r-src", 10_000, operation_id: "pay-r", occurred_on: "2027-01-10")

      transfer(conn, "r-src", "r-dst", 4_000,
        operation_id: "r-transfer",
        occurred_on: "2027-01-15"
      )

      reduce(conn, "pay-r", 7_000, operation_id: "r-reduce", occurred_on: "2027-01-20")

      data = report_data(conn, "2027-01-20")

      # The newest allocations lived at the destination, so it was drained
      # first; the reduction reports per property where cash was removed.
      assert cash_entry(data, "rot-park")["movements"]["reduced_cents"] == 4_000
      assert cash_entry(data, "rot-park")["closing_held_cents"] == 0

      assert cash_entry(data, "ams-canal")["movements"]["reduced_cents"] == 3_000
      assert cash_entry(data, "ams-canal")["closing_held_cents"] == 3_000

      assert ledger(conn)["cash_held_cents"] == 3_000
    end

    test "chargebacks reverse settlements as negative movements plus charged-back cash", %{
      conn: conn
    } do
      start(conn, "2027-01-01")

      open(conn, "c-src", arrival_on: "2027-03-31")
      pay(conn, "c-src", 5_000, operation_id: "pay-c", occurred_on: "2027-01-10")
      cancel(conn, "c-src", "2027-02-20", operation_id: "cancel-c")

      charge_back(conn, "pay-c", operation_id: "cb-c", occurred_on: "2027-03-01")

      data = report_data(conn, "2027-03-01")

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 zero_cash_movements()
                 | "refunded_cents" => -5_000,
                   "charged_back_cents" => 5_000
               },
               "closing_held_cents" => 0
             }
    end

    test "chargebacks reverse a settlement at the property that settled it, not the original",
         %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "cb-src", property_id: "ams-canal", arrival_on: "2027-03-31")
      open(conn, "cb-dst", property_id: "rot-park", arrival_on: "2027-03-31")

      pay(conn, "cb-src", 6_000, operation_id: "pay-cb", occurred_on: "2027-01-10")

      transfer(conn, "cb-src", "cb-dst", 4_000,
        operation_id: "cb-transfer",
        occurred_on: "2027-01-15"
      )

      # The destination settles the transferred cash refundably.
      cancel(conn, "cb-dst", "2027-02-01", operation_id: "cb-cancel-dst")

      charge_back(conn, "pay-cb", operation_id: "cb-op", occurred_on: "2027-02-10")

      data = report_data(conn, "2027-02-10")

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2_000,
               "movements" => %{zero_cash_movements() | "charged_back_cents" => 2_000},
               "closing_held_cents" => 0
             }

      # The refund reversal follows the cash to the property (rot-park) that
      # settled it and never touches the payment's original property's
      # refunded column.
      assert cash_entry(data, "rot-park") == %{
               "property_id" => "rot-park",
               "opening_held_cents" => 0,
               "movements" => %{
                 zero_cash_movements()
                 | "refunded_cents" => -4_000,
                   "charged_back_cents" => 4_000
               },
               "closing_held_cents" => 0
             }

      assert ledger(conn)["cash_charged_back_cents"] == 6_000
      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_held_cents"] == 0
    end
  end

  describe "credit movements" do
    test "converted cash, revoked entitlement, and absorbed restores reconcile", %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "src", arrival_on: "2027-03-31")
      pay(conn, "src", 10_000, operation_id: "pay-a", occurred_on: "2027-01-10")

      cancel(conn, "src", "2027-02-20",
        operation_id: "cancel-a",
        refund_method: "hotel_credit"
      )

      open(conn, "dst", arrival_on: "2027-03-31")
      apply_credit(conn, "dst", 8_000, "2027-02-25", operation_id: "apply-a")

      # The lot holds 11_000: 8_000 is applied, 3_000 remains available.
      data = report_data(conn, "2027-02-26")

      assert data["credit"]["opening_liability_cents"] == 11_000

      assert data["credit"]["movements"] == zero_credit_movements()

      assert data["credit"]["closing_liability_cents"] == 11_000

      # The chargeback revokes the entitlement that can still be recovered.
      charge_back(conn, "pay-a", operation_id: "cb-a", occurred_on: "2027-03-01")

      # The refundable cancellation restores the applied credit; the clawback
      # absorbs it before it could become available again.
      cancel(conn, "dst", "2027-03-01", operation_id: "cancel-d")

      data = report_data(conn, "2027-03-01")

      assert data["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => %{
                 zero_credit_movements()
                 | "revoked_cents" => 3_000,
                   "absorbed_cents" => 8_000
               },
               "closing_liability_cents" => 0
             }

      assert cash_entry(data, "ams-canal")["movements"] == %{
               zero_cash_movements()
               | "converted_to_credit_cents" => -10_000,
                 "charged_back_cents" => 10_000
             }

      assert ledger(conn, "?on=2027-03-01")["credit_liability_cents"] == 0
      assert ledger(conn, "?on=2027-03-01")["credit_shortfall_cents"] == 0
    end

    test "credit that expires shows an expiry movement even without operations", %{conn: conn} do
      # A lot created before reporting began, expiring after starts_on.
      open(conn, "pre-src",
        arrival_on: "2026-12-15",
        booked_on: "2026-10-03",
        operation_id: "open-pre",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "pre-src", 5_000, operation_id: "pay-pre", occurred_on: "2026-11-10")

      cancel(conn, "pre-src", "2026-12-01",
        operation_id: "cancel-pre",
        refund_method: "hotel_credit"
      )

      # expires_on is 2026-12-01 + 366 = 2027-12-02.
      start(conn, "2027-01-01")

      data = report_data(conn, "2027-12-01")

      assert data["credit"]["opening_liability_cents"] == 5_500
      assert data["credit"]["movements"]["expired_cents"] == 0
      assert data["credit"]["closing_liability_cents"] == 5_500

      # No partner operation was submitted on the expiry date.
      data = report_data(conn, "2027-12-02")

      assert data["credit"] == %{
               "opening_liability_cents" => 5_500,
               "movements" => %{zero_credit_movements() | "expired_cents" => 5_500},
               "closing_liability_cents" => 0
             }

      assert report_data(conn, "2027-12-02") == data
      assert ledger(conn, "?on=2027-12-02")["credit_liability_cents"] == 0
      assert ledger(conn, "?on=2027-12-01")["credit_liability_cents"] == 5_500
    end

    test "credit restored after its expiry expires immediately at the settlement", %{conn: conn} do
      open(conn, "pre-src",
        arrival_on: "2026-06-01",
        booked_on: "2026-01-05",
        operation_id: "open-pre",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "pre-src", 5_000, operation_id: "pay-pre", occurred_on: "2026-03-01")

      cancel(conn, "pre-src", "2026-05-01",
        operation_id: "cancel-pre",
        refund_method: "hotel_credit"
      )

      # expires_on is 2026-05-01 + 366 = 2027-05-02.
      start(conn, "2027-01-01")

      open(conn, "y-group",
        arrival_on: "2027-06-15",
        operation_id: "open-y",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      apply_credit(conn, "y-group", 3_000, "2027-02-01", operation_id: "apply-y")

      # The lot expired on 2027-05-02. Cancelling after that restores the
      # applied credit straight into an expiry movement.
      cancel(conn, "y-group", "2027-05-10", operation_id: "cancel-y")

      data = report_data(conn, "2027-05-10")

      assert data["credit"]["movements"]["expired_cents"] == 3_000
      assert data["credit"]["closing_liability_cents"] == 0

      assert ledger(conn, "?on=2027-05-10")["credit_liability_cents"] == 0
    end

    test "applying credit has no movement column", %{conn: conn} do
      open(conn, "pre-src",
        arrival_on: "2026-12-15",
        booked_on: "2026-10-03",
        operation_id: "open-pre",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "pre-src", 5_000, operation_id: "pay-pre", occurred_on: "2026-11-10")

      cancel(conn, "pre-src", "2026-12-01",
        operation_id: "cancel-pre",
        refund_method: "hotel_credit"
      )

      start(conn, "2027-01-01")

      open(conn, "z-group",
        arrival_on: "2027-03-31",
        operation_id: "open-z",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      apply_credit(conn, "z-group", 2_000, "2027-01-20", operation_id: "apply-z")

      data = report_data(conn, "2027-01-20")

      assert data["credit"]["opening_liability_cents"] == 5_500
      assert data["credit"]["movements"] == zero_credit_movements()
      assert data["credit"]["closing_liability_cents"] == 5_500
    end
  end

  describe "rejected and durable operations" do
    test "rejected operations leave no movement while later operations still move", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      results =
        submit_all(conn, [
          %{
            "operation_id" => "pay-ok",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-10",
            "group_id" => "group-81",
            "amount_cents" => 4_000
          },
          %{
            "operation_id" => "pay-skip",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-10",
            "group_id" => "group-81",
            "amount_cents" => 500
          },
          %{
            "operation_id" => "pay-bad",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-10",
            "group_id" => "group-81",
            "amount_cents" => 9_999_999
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected"]

      data = report_data(conn, "2027-01-10")

      assert data["cash"]
             |> hd()
             |> Map.fetch!("movements")
             |> Map.fetch!("received_cents") == 4_500
    end

    test "a durable retry returns its stored result and does not move twice", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      op = %{
        "operation_id" => "pay-retry",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-10",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      }

      first = submit(conn, op)
      second = submit(conn, op)

      assert first == second

      assert submit(conn, Map.put(op, "expected_revision", 1))["code"] ==
               "operation_id_conflict"

      data = report_data(conn, "2027-01-10")

      assert data["cash"]
             |> hd()
             |> Map.fetch!("movements")
             |> Map.fetch!("received_cents") == 4_000
    end

    test "equivalent batches and sequential submissions produce equivalent reports", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      pay(conn, "group-81", 3_000, operation_id: "seq-1", occurred_on: "2027-02-01")
      pay(conn, "group-81", 2_000, operation_id: "seq-2", occurred_on: "2027-02-01")

      sequential = report_data(conn, "2027-02-01")

      pay(conn, "group-81", 1_000, operation_id: "seq-3", occurred_on: "2027-02-01")

      assert report_data(conn, "2027-02-01") == %{
               sequential
               | "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 0,
                     "movements" => %{zero_cash_movements() | "received_cents" => 6_000},
                     "closing_held_cents" => 6_000
                   }
                 ]
             }
    end

    test "report totals reconcile with the ledger views", %{conn: conn} do
      start(conn, "2027-01-01")

      open(conn, "g-a", property_id: "ams-canal", arrival_on: "2027-03-31")
      open(conn, "g-b", property_id: "rot-park", arrival_on: "2027-04-30")

      pay(conn, "g-a", 6_000, operation_id: "led-pay-a", occurred_on: "2027-02-01")
      pay(conn, "g-b", 4_000, operation_id: "led-pay-b", occurred_on: "2027-02-01")

      cancel(conn, "g-b", "2027-03-01", operation_id: "led-cancel-b")

      data = report_data(conn, "2027-03-01")

      assert Enum.sum(Enum.map(data["cash"], & &1["closing_held_cents"])) ==
               ledger(conn, "?on=2027-03-01")["cash_held_cents"]

      assert data["credit"]["closing_liability_cents"] ==
               ledger(conn, "?on=2027-03-01")["credit_liability_cents"]
    end
  end
end
