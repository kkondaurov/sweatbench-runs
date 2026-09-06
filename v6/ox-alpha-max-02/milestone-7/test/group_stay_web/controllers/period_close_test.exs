defmodule GroupStayWeb.Controllers.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp start_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-11-01"
      },
      overrides
    )
  end

  defp close_operation(period_end_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-close",
        "type" => "close_finance_period",
        "period_end_on" => period_end_on
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount, occurred_on \\ "2026-11-02") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-" <> group_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp charge_back(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp fetch_report!(conn, date) do
    response = get(conn, "/api/v1/finance/daily-report?date=#{date}")
    assert response.status == 200
    json_response(response, 200)["data"]
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

  defp cash_entry(property_id, opening, closing, movements_override \\ %{}) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movements_override),
      "closing_held_cents" => closing
    }
  end

  defp credit_section(opening, closing, movements_override \\ %{}) do
    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(zero_credit_movements(), movements_override),
      "closing_liability_cents" => closing
    }
  end

  defp late_cash(property_id, movements_override) do
    %{
      "property_id" => property_id,
      "movements" => Map.merge(zero_cash_movements(), movements_override)
    }
  end

  describe "closing through a date" do
    test "the applied result contains exactly the operation identifier, status, and cutoff", %{
      conn: conn
    } do
      results = run_batch(conn, [start_operation(), close_operation("2026-11-15")])

      assert results == [
               %{
                 "operation_id" => "op-start",
                 "status" => "applied",
                 "starts_on" => "2026-11-01"
               },
               %{
                 "operation_id" => "op-close",
                 "status" => "applied",
                 "period_end_on" => "2026-11-15"
               }
             ]

      assert map_size(Enum.at(results, 1)) == 3
    end

    test "rejects a close before finance reporting has started and remembers it", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               run_batch(conn, [close_operation("2026-11-15")])

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               fetch_operation(conn, "op-close")
    end

    test "a close before the start in the same batch rejects without blocking the start", %{
      conn: conn
    } do
      assert [
               %{"operation_id" => "c-first", "status" => "rejected", "code" => "invalid_period"},
               %{"operation_id" => "op-start", "status" => "applied"}
             ] =
               run_batch(conn, [
                 close_operation("2026-11-15", %{"operation_id" => "c-first"}),
                 start_operation()
               ])
    end

    test "rejects a missing or invalid period_end_on", %{conn: conn} do
      bare = %{"type" => "close_finance_period"}

      results =
        run_batch(conn, [
          start_operation(),
          Map.put(bare, "operation_id", "c-missing"),
          bare |> Map.put("operation_id", "c-garbage") |> Map.put("period_end_on", "not-a-date"),
          bare
          |> Map.put("operation_id", "c-impossible")
          |> Map.put("period_end_on", "2026-02-30"),
          bare |> Map.put("operation_id", "c-number") |> Map.put("period_end_on", 20_261_115)
        ])

      rejections = Enum.drop(results, 1)

      assert Enum.all?(
               rejections,
               &(&1["status"] == "rejected" and &1["code"] == "invalid_period")
             )

      assert Enum.map(rejections, & &1["operation_id"]) ==
               ~w(c-missing c-garbage c-impossible c-number)
    end

    test "the cutoff must fall on or after starts_on; the start date itself is allowed", %{
      conn: conn
    } do
      run_batch(conn, [start_operation()])

      assert [
               %{"operation_id" => "c-early", "status" => "rejected", "code" => "invalid_period"},
               %{
                 "operation_id" => "c-on-start",
                 "status" => "applied",
                 "period_end_on" => "2026-11-01"
               }
             ] =
               run_batch(conn, [
                 close_operation("2026-10-31", %{"operation_id" => "c-early"}),
                 close_operation("2026-11-01", %{"operation_id" => "c-on-start"})
               ])
    end

    test "each close must be strictly later than the latest successful close", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        close_operation("2026-11-15", %{"operation_id" => "c1"})
      ])

      assert [
               %{"operation_id" => "c-same", "status" => "rejected", "code" => "invalid_period"},
               %{
                 "operation_id" => "c-before",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{"operation_id" => "c2", "status" => "applied", "period_end_on" => "2026-11-20"}
             ] =
               run_batch(conn, [
                 close_operation("2026-11-15", %{"operation_id" => "c-same"}),
                 close_operation("2026-11-14", %{"operation_id" => "c-before"}),
                 close_operation("2026-11-20", %{"operation_id" => "c2"})
               ])

      # The comparison is always against the newest close, not the earliest.
      assert [
               %{
                 "operation_id" => "c-between",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ] =
               run_batch(conn, [close_operation("2026-11-16", %{"operation_id" => "c-between"})])
    end

    test "replaying an applied close returns its stored result; a changed payload conflicts", %{
      conn: conn
    } do
      run_batch(conn, [start_operation(), close_operation("2026-11-15")])

      stored = %{
        "operation_id" => "op-close",
        "status" => "applied",
        "period_end_on" => "2026-11-15"
      }

      assert [^stored] = run_batch(conn, [close_operation("2026-11-15")])

      # A different cutoff under the same identifier never revalidates: it conflicts.
      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               run_batch(conn, [close_operation("2026-11-16")])

      assert fetch_operation(conn, "op-close") == stored
    end
  end

  describe "published reports" do
    test "reports through the cutoff return closed and later ones stay open", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000, "2026-11-02"),
        close_operation("2026-11-15")
      ])

      assert fetch_report!(conn, "2026-11-02")["status"] == "closed"
      assert fetch_report!(conn, "2026-11-15")["status"] == "closed"
      assert fetch_report!(conn, "2026-11-16")["status"] == "open"
      assert fetch_report!(conn, "2027-01-31")["status"] == "open"
    end

    test "closed reports stay stable across later operations, later closes, and repeated reads",
         %{
           conn: conn
         } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 10_000, "2026-11-02"),
        close_operation("2026-11-15", %{"operation_id" => "c1"})
      ])

      frozen = fetch_report!(conn, "2026-11-02")

      run_batch(conn, [
        payment("p2", "group-81", 2_000, "2026-11-03"),
        close_operation("2026-12-31", %{"operation_id" => "c2"}),
        payment("p3", "group-81", 4_000, "2027-01-05")
      ])

      assert fetch_report!(conn, "2026-11-02") == frozen
      assert fetch_report!(conn, "2026-11-02") == frozen
    end

    test "closing freezes a formerly open report with everything it contained", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        close_operation("2026-11-15", %{"operation_id" => "c1"})
      ])

      run_batch(conn, [payment("p1", "group-81", 2_000, "2026-11-03")])

      before = fetch_report!(conn, "2026-11-16")
      assert before["status"] == "open"

      run_batch(conn, [close_operation("2026-11-20", %{"operation_id" => "c2"})])

      after_close = fetch_report!(conn, "2026-11-16")
      assert after_close["status"] == "closed"

      # Publishing flips the status but leaves the data value untouched.
      for field <- ["date", "cash", "credit", "late_adjustments"] do
        assert Map.fetch!(after_close, field) == Map.fetch!(before, field)
      end

      # Later operations cannot disturb it any more either.
      run_batch(conn, [payment("p2", "group-81", 9_999, "2026-11-17")])
      refetched = fetch_report!(conn, "2026-11-16")
      assert refetched == after_close
    end
  end

  describe "posting after a close" do
    test "an operation immediately before a close posts into the period being closed", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("early", "group-81", 3_000, "2026-11-14"),
        close_operation("2026-11-15")
      ])

      report = fetch_report!(conn, "2026-11-14")

      assert report["status"] == "closed"

      assert report["cash"] == [
               cash_entry("ams-canal", 0, 3_000, %{"received_cents" => 3_000})
             ]

      # Posted normally before the close existed, so it is not a late adjustment.
      assert report["late_adjustments"]["cash"] == []
    end

    test "an old-dated operation immediately after a close posts on the first open day", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        close_operation("2026-11-15", %{"operation_id" => "c1"})
      ])

      run_batch(conn, [payment("late-pay", "group-81", 2_500, "2026-11-05")])

      day = fetch_report!(conn, "2026-11-16")

      assert day["status"] == "open"

      assert day["cash"] == [
               cash_entry("ams-canal", 0, 2_500, %{"received_cents" => 2_500})
             ]

      assert day["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{"received_cents" => 2_500})
             ]

      # The closed day it would have landed on is untouched.
      assert fetch_report!(conn, "2026-11-05")["cash"] == []
    end

    test "operations on either side of a close in one batch post to their own sides", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("before", "group-81", 1_000, "2026-11-04"),
        close_operation("2026-11-10", %{"operation_id" => "c1"}),
        payment("after", "group-81", 2_000, "2026-11-08")
      ])

      assert fetch_report!(conn, "2026-11-04")["cash"] == [
               cash_entry("ams-canal", 0, 1_000, %{"received_cents" => 1_000})
             ]

      first_open = fetch_report!(conn, "2026-11-11")
      assert first_open["status"] == "open"

      # The earlier payment is prior history by now and shows up in the opening.
      assert first_open["cash"] == [
               cash_entry("ams-canal", 1_000, 3_000, %{"received_cents" => 2_000})
             ]
    end

    test "a close changes only reporting; current-state views keep their meanings", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 5_000),
        close_operation("2026-11-30", %{"operation_id" => "c1"})
      ])

      run_batch(conn, [
        close_operation("2026-12-15", %{"operation_id" => "c2"}),
        payment("p2", "group-81", 1_000, "2026-11-10")
      ])

      assert fetch_ledger(conn)["cash_held_cents"] == 6_000

      group = fetch_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 6_000
      # Closes never advance a revision; only the late-posted payment did.
      assert group["revision"] == 3

      assert fetch_payment(conn, "p1")["held_cents"] == 5_000
      assert fetch_payment(conn, "p2")["held_cents"] == 1_000
    end
  end

  describe "identifying late adjustments" do
    test "charging back refunded cash keeps both signed classifications in the late block", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 6_000),
        cancel("group-81", "2026-11-26"),
        close_operation("2026-11-30", %{"operation_id" => "c1"}),
        charge_back("cb-1", "p1", "2026-11-28")
      ])

      day = fetch_report!(conn, "2026-12-01")

      assert day["status"] == "open"

      # The day's total movement carries both classifications.
      assert day["cash"] == [
               cash_entry("ams-canal", 0, 0, %{
                 "refunded_cents" => -6_000,
                 "charged_back_cents" => 6_000
               })
             ]

      # The zero-net pair must not disappear inside the late block either.
      assert day["late_adjustments"] == %{
               "cash" => [
                 late_cash("ams-canal", %{
                   "refunded_cents" => -6_000,
                   "charged_back_cents" => 6_000
                 })
               ],
               "credit" => zero_credit_movements()
             }
    end

    test "late cash is ordered by property, omits all-zero properties, and sits beside ordinary movements",
         %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 4_000, "2026-11-02"),
        open_operation(%{
          "operation_id" => "op-open-rtm",
          "group_id" => "g-rtm",
          "property_id" => "rtm-haven",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-26",
          "rooms" => [%{"room_id" => "room-r", "nightly_rate_cents" => 10_000}]
        }),
        payment("p2", "g-rtm", 3_000, "2026-11-03"),
        close_operation("2026-11-30", %{"operation_id" => "c1"}),
        %{
          "operation_id" => "red-1",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-11-09",
          "payment_operation_id" => "p2",
          "amount_cents" => 1_000
        },
        payment("p3", "group-81", 2_500, "2026-12-01")
      ])

      day = fetch_report!(conn, "2026-12-01")

      # Ordinary and late amounts combine into each day's total movements.
      assert day["cash"] == [
               cash_entry("ams-canal", 4_000, 6_500, %{"received_cents" => 2_500}),
               cash_entry("rtm-haven", 3_000, 2_000, %{"reduced_cents" => 1_000})
             ]

      # Only the moved-forward portion appears as a late adjustment, ordered
      # by property_id; ams-canal had no late movement and is omitted.
      assert day["late_adjustments"]["cash"] == [
               late_cash("rtm-haven", %{"reduced_cents" => 1_000})
             ]

      assert day["late_adjustments"]["credit"] == zero_credit_movements()
    end

    test "a late chargeback revoking converted cash reports late credit and cash classifications",
         %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 6_000),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
        close_operation("2026-11-30", %{"operation_id" => "c1"}),
        charge_back("cb-1", "p1", "2026-11-28")
      ])

      day = fetch_report!(conn, "2026-12-01")

      assert day["credit"] == credit_section(6_600, 6_000, %{"revoked_cents" => 600})

      assert day["late_adjustments"]["credit"] ==
               Map.merge(zero_credit_movements(), %{"revoked_cents" => 600})

      assert day["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{
                 "converted_to_credit_cents" => -6_000,
                 "charged_back_cents" => 6_000
               })
             ]
    end

    test "computed expiry is never a late adjustment", %{conn: conn} do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 6_000),
        cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
        close_operation("2026-11-30", %{"operation_id" => "c1"})
      ])

      # The lot issued 2026-11-26 expires on the day after 366 days.
      expiry_day = Date.add(~D[2026-11-26], 367) |> Date.to_iso8601()
      report = fetch_report!(conn, expiry_day)

      assert report["credit"] == credit_section(6_600, 0, %{"expired_cents" => 6_600})
      assert report["late_adjustments"]["credit"] == zero_credit_movements()
      assert report["late_adjustments"]["cash"] == []
    end

    test "reports with no late movements still carry an empty late_adjustments block", %{
      conn: conn
    } do
      run_batch(conn, [
        start_operation(),
        open_operation(),
        payment("p1", "group-81", 1_000),
        close_operation("2026-11-15", %{"operation_id" => "c1"})
      ])

      assert fetch_report!(conn, "2026-11-02")["late_adjustments"] == %{
               "cash" => [],
               "credit" => zero_credit_movements()
             }
    end
  end
end
