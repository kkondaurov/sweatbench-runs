defmodule GroupStayWeb.PeriodCloseTest do
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

    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :booked_on, "2027-01-01"),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => Keyword.get(opts, :property_id, "ams-canal"),
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
      ]
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

  defp close(conn, period_end_on, operation_id \\ "close-1") do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
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

  defp late_entry(data, property_id) do
    Enum.find(data["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
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

  defp empty_late_adjustments do
    %{"cash" => [], "credit" => zero_credit_movements()}
  end

  describe "closing a finance period" do
    test "applies with exactly its result and replays durably", %{conn: conn} do
      start(conn, "2027-01-01")

      result = close(conn, "2027-01-10", "close-1")

      assert result == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2027-01-10"
             }

      assert close(conn, "2027-01-10", "close-1") == result

      assert conn |> get("/api/v1/operations/close-1") |> json_response(200) |> Map.fetch!("data") ==
               result
    end

    test "a different payload reusing the identifier is rejected", %{conn: conn} do
      start(conn, "2027-01-01")
      close(conn, "2027-01-10", "close-1")

      assert submit(conn, %{
               "operation_id" => "close-1",
               "type" => "close_finance_period",
               "period_end_on" => "2027-01-20"
             }) == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end

    test "rejects closes before reporting, before starts_on, and at or before the latest cutoff",
         %{conn: conn} do
      assert close(conn, "2027-01-10", "close-pre") == %{
               "operation_id" => "close-pre",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      start(conn, "2027-01-05")

      assert close(conn, "2027-01-04", "close-before-start")["code"] == "invalid_period"
      assert close(conn, "2027-01-05", "close-1")["status"] == "applied"

      assert close(conn, "2027-01-05", "close-same")["code"] == "invalid_period"
      assert close(conn, "2027-01-04", "close-earlier")["code"] == "invalid_period"

      assert close(conn, "2027-01-20", "close-2")["status"] == "applied"
    end

    test "rejects a missing or invalid period_end_on with invalid_period", %{conn: conn} do
      start(conn, "2027-01-01")

      assert submit(conn, %{
               "operation_id" => "close-bad",
               "type" => "close_finance_period",
               "period_end_on" => "2027-02-30"
             }) == %{
               "operation_id" => "close-bad",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert submit(conn, %{
               "operation_id" => "close-missing",
               "type" => "close_finance_period"
             }) == %{
               "operation_id" => "close-missing",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      # Rejections publish nothing.
      assert report_data(conn, "2027-01-20")["status"] == "open"
    end

    test "a rejected close is remembered durably even when later times would accept it", %{
      conn: conn
    } do
      op = %{
        "operation_id" => "close-first",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-10"
      }

      result = submit(conn, op)

      assert result == %{
               "operation_id" => "close-first",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      start(conn, "2027-01-01")

      # The retry still receives the original rejection.
      assert submit(conn, op) == result

      # A fresh identifier with the same date now applies.
      assert close(conn, "2027-01-10", "close-2")["status"] == "applied"
    end

    test "closes in the same batch observe earlier closes", %{conn: conn} do
      start(conn, "2027-01-01")

      results =
        submit_all(conn, [
          %{
            "operation_id" => "close-a",
            "type" => "close_finance_period",
            "period_end_on" => "2027-01-10"
          },
          %{
            "operation_id" => "close-b",
            "type" => "close_finance_period",
            "period_end_on" => "2027-01-20"
          },
          %{
            "operation_id" => "close-c",
            "type" => "close_finance_period",
            "period_end_on" => "2027-01-10"
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected"]

      assert report_data(conn, "2027-01-15")["status"] == "closed"
      assert report_data(conn, "2027-01-21")["status"] == "open"
    end
  end

  describe "published reports" do
    test "reports through the cutoff are published and stay stable", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      pay(conn, "group-81", 3_000, operation_id: "pay-1", occurred_on: "2027-01-05")
      pay(conn, "group-81", 1_000, operation_id: "pay-2", occurred_on: "2027-01-08")

      before = report_data(conn, "2027-01-06")
      assert before["status"] == "open"

      close(conn, "2027-01-10")

      closed = report_data(conn, "2027-01-06")
      assert closed == %{before | "status" => "closed"}

      # A day with no activity whatsoever is still published.
      assert report_data(conn, "2027-01-02") == %{
               "date" => "2027-01-02",
               "status" => "closed",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => empty_late_adjustments()
             }

      assert report_data(conn, "2027-01-11")["status"] == "open"

      # Later operations, later closes, and repeated reads never touch it.
      pay(conn, "group-81", 2_000, operation_id: "pay-late", occurred_on: "2027-01-07")
      close(conn, "2027-01-15", "close-2")

      assert report_data(conn, "2027-01-06") == closed
      assert report_data(conn, "2027-01-06") == closed
      assert report_data(conn, "2027-01-16")["status"] == "open"
    end

    test "an operation immediately before the close posts into the period being closed",
         %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")

      results =
        submit_all(conn, [
          %{
            "operation_id" => "pay-pre",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-05",
            "group_id" => "group-81",
            "amount_cents" => 3_000
          },
          %{
            "operation_id" => "close-1",
            "type" => "close_finance_period",
            "period_end_on" => "2027-01-10"
          },
          %{
            "operation_id" => "pay-post",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-08",
            "group_id" => "group-81",
            "amount_cents" => 1_000
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]

      data = report_data(conn, "2027-01-10")
      assert data["status"] == "closed"
      assert cash_entry(data, "ams-canal")["opening_held_cents"] == 3_000
      assert cash_entry(data, "ams-canal")["movements"] == zero_cash_movements()
      assert cash_entry(data, "ams-canal")["closing_held_cents"] == 3_000

      open_day = report_data(conn, "2027-01-11")
      assert open_day["status"] == "open"

      assert open_day["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{zero_cash_movements() | "received_cents" => 1_000}
                 }
               ],
               "credit" => zero_credit_movements()
             }

      assert cash_entry(open_day, "ams-canal")["opening_held_cents"] == 3_000
      assert cash_entry(open_day, "ams-canal")["movements"] == zero_cash_movements()
      assert cash_entry(open_day, "ams-canal")["closing_held_cents"] == 4_000
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts on the first open day as a late adjustment", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")
      close(conn, "2027-01-10")

      pay(conn, "group-81", 2_000, operation_id: "pay-old", occurred_on: "2027-01-08")

      data = report_data(conn, "2027-01-11")

      assert data["status"] == "open"
      assert cash_entry(data, "ams-canal")["opening_held_cents"] == 0
      assert cash_entry(data, "ams-canal")["movements"] == zero_cash_movements()
      assert cash_entry(data, "ams-canal")["closing_held_cents"] == 2_000

      assert data["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{zero_cash_movements() | "received_cents" => 2_000}
                 }
               ],
               "credit" => zero_credit_movements()
             }

      # The closed period stays untouched.
      before = report_data(conn, "2027-01-08")
      assert before["status"] == "closed"
      assert before["cash"] == []

      # The ledger keeps its current-state meaning.
      assert ledger(conn)["cash_held_cents"] == 2_000
    end

    test "an operation dated in the open period keeps its own date", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")
      close(conn, "2027-01-10")

      pay(conn, "group-81", 2_000, operation_id: "pay-open", occurred_on: "2027-01-15")

      data = report_data(conn, "2027-01-15")

      assert data["late_adjustments"] == empty_late_adjustments()

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{zero_cash_movements() | "received_cents" => 2_000},
               "closing_held_cents" => 2_000
             }
    end

    test "a later close never moves an already-committed posting", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")
      close(conn, "2027-01-10")

      pay(conn, "group-81", 2_000, operation_id: "pay-old", occurred_on: "2027-01-08")

      first_open_day = report_data(conn, "2027-01-11")
      assert first_open_day["status"] == "open"

      close(conn, "2027-01-20", "close-2")

      published = report_data(conn, "2027-01-11")

      assert published["status"] == "closed"
      assert published["late_adjustments"] == first_open_day["late_adjustments"]
      assert published["cash"] == first_open_day["cash"]
      assert published["credit"] == first_open_day["credit"]

      # Nothing was pushed to the next open day.
      assert report_data(conn, "2027-01-21")["late_adjustments"] == empty_late_adjustments()
    end

    test "late adjustments order cash by property_id and omit all-zero properties",
         %{conn: conn} do
      open(conn, "g-zeta", property_id: "zeta-lodge", operation_id: "open-zeta")
      open(conn, "g-alpha", property_id: "alpha-lodge", operation_id: "open-alpha")

      start(conn, "2027-01-01")
      close(conn, "2027-01-10")

      pay(conn, "g-zeta", 1_000, operation_id: "pay-zeta", occurred_on: "2027-01-05")
      pay(conn, "g-alpha", 2_000, operation_id: "pay-alpha", occurred_on: "2027-01-07")

      data = report_data(conn, "2027-01-11")

      assert Enum.map(data["late_adjustments"]["cash"], & &1["property_id"]) == [
               "alpha-lodge",
               "zeta-lodge"
             ]

      assert late_entry(data, "zeta-lodge")["movements"] ==
               %{zero_cash_movements() | "received_cents" => 1_000}

      assert late_entry(data, "alpha-lodge")["movements"] ==
               %{zero_cash_movements() | "received_cents" => 2_000}
    end

    test "a late chargeback keeps signed refunded and charged-back classifications", %{
      conn: conn
    } do
      open(conn, "g-cb", arrival_on: "2027-03-31")
      start(conn, "2027-01-01")

      pay(conn, "g-cb", 5_000, operation_id: "pay-cb", occurred_on: "2027-01-10")
      cancel(conn, "g-cb", "2027-02-20", operation_id: "cancel-cb")

      close(conn, "2027-02-25")

      charge_back(conn, "pay-cb", operation_id: "cb-op", occurred_on: "2027-02-22")

      data = report_data(conn, "2027-02-26")

      assert data["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{
                     zero_cash_movements()
                     | "refunded_cents" => -5_000,
                       "charged_back_cents" => 5_000
                   }
                 }
               ],
               "credit" => zero_credit_movements()
             }

      # The net balance effect is zero, so the property carries no ordinary
      # entry, but the signed late adjustment is still reported.
      assert data["cash"] == []
    end

    test "a late conversion reports its cash and credit effects in late_adjustments", %{
      conn: conn
    } do
      open(conn, "g-conv", arrival_on: "2027-03-31")
      start(conn, "2027-01-01")

      pay(conn, "g-conv", 6_000, operation_id: "pay-conv", occurred_on: "2027-01-10")

      close(conn, "2027-01-15")

      cancel(conn, "g-conv", "2027-01-12",
        operation_id: "cancel-conv",
        refund_method: "hotel_credit"
      )

      data = report_data(conn, "2027-01-16")

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 6_000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 0
             }

      assert data["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{zero_cash_movements() | "converted_to_credit_cents" => 6_000}
                 }
               ],
               "credit" => %{zero_credit_movements() | "issued_cents" => 6_600}
             }

      assert data["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => zero_credit_movements(),
               "closing_liability_cents" => 6_600
             }
    end

    test "a day can carry ordinary and late movements side by side", %{conn: conn} do
      open(conn, "group-81")
      start(conn, "2027-01-01")
      close(conn, "2027-01-10")

      pay(conn, "group-81", 2_000, operation_id: "pay-now", occurred_on: "2027-01-11")
      # posts ordinarily on the first open day
      data = report_data(conn, "2027-01-11")
      assert data["late_adjustments"] == empty_late_adjustments()

      # An old-dated payment lands on the same open day as a late adjustment.
      pay(conn, "group-81", 1_000, operation_id: "pay-old", occurred_on: "2027-01-08")

      data = report_data(conn, "2027-01-11")

      assert cash_entry(data, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{zero_cash_movements() | "received_cents" => 2_000},
               "closing_held_cents" => 3_000
             }

      assert data["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{zero_cash_movements() | "received_cents" => 1_000}
                 }
               ],
               "credit" => zero_credit_movements()
             }

      # The next day opens on both the ordinary and the late movement.
      next = report_data(conn, "2027-01-12")

      assert cash_entry(next, "ams-canal")["opening_held_cents"] == 3_000
      assert cash_entry(next, "ams-canal")["movements"] == zero_cash_movements()
      assert cash_entry(next, "ams-canal")["closing_held_cents"] == 3_000
      assert next["late_adjustments"] == empty_late_adjustments()
    end
  end
end
