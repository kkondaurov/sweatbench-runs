defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  defp start_reporting(overrides \\ %{}) do
    %{
      "operation_id" => "op-start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-01"
    }
    |> Map.merge(overrides)
  end

  defp close_period(overrides \\ %{}) do
    %{
      "operation_id" => "op-close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-11-30"
    }
    |> Map.merge(overrides)
  end

  defp report_path(date), do: "/api/v1/finance/daily-report?date=#{date}"

  defp daily_report(conn, date) do
    json_response(get(conn, report_path(date)), 200)["data"]
  end

  defp cash_movements(overrides \\ %{}) do
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
    |> Map.merge(overrides)
  end

  defp credit_movements(overrides \\ %{}) do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
    |> Map.merge(overrides)
  end

  defp late_adjustments(overrides \\ %{}) do
    %{
      "cash" => [],
      "credit" => credit_movements()
    }
    |> Map.merge(overrides)
  end

  defp ams_late(movements) do
    %{"property_id" => "ams-canal", "movements" => movements}
  end

  describe "closing through a date" do
    test "applies a close with its exact result and publishes reports through the cutoff", %{
      conn: conn
    } do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 5_000
        })
      )

      conn = json_post(conn, close_period())

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-close",
                   "status" => "applied",
                   "period_end_on" => "2026-11-30"
                 }
               ]
             }

      assert daily_report(conn, "2026-11-30")["status"] == "closed"
      assert daily_report(conn, "2026-11-01")["status"] == "closed"

      open_day = daily_report(conn, "2026-12-01")
      assert open_day["status"] == "open"
      assert open_day["late_adjustments"] == late_adjustments()
    end

    test "a half-open period can be closed from starts_on and then extended", %{conn: conn} do
      json_post(conn, start_reporting())

      # Closing exactly starts_on is on or after starts_on and applies.
      assert [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-10-05"
               }
             ] =
               json_response(
                 json_post(
                   conn,
                   close_period(%{"operation_id" => "close-1", "period_end_on" => "2026-10-05"})
                 ),
                 200
               )["results"]

      assert daily_report(conn, "2026-10-05")["status"] == "closed"
      assert daily_report(conn, "2026-10-06")["status"] == "open"

      # A strictly later close extends the closed range.
      assert [
               %{
                 "operation_id" => "close-2",
                 "status" => "applied",
                 "period_end_on" => "2026-11-15"
               }
             ] =
               json_response(
                 json_post(
                   conn,
                   close_period(%{"operation_id" => "close-2", "period_end_on" => "2026-11-15"})
                 ),
                 200
               )["results"]

      assert daily_report(conn, "2026-11-15")["status"] == "closed"
      assert daily_report(conn, "2026-11-16")["status"] == "open"
    end

    test "rejects every invalid close with invalid_period", %{conn: conn} do
      # Before reporting has started.
      assert [
               %{"status" => "rejected", "code" => "invalid_period"}
             ] =
               json_response(json_post(conn, close_period(%{"operation_id" => "pre-start"})), 200)[
                 "results"
               ]

      json_post(conn, start_reporting())

      # Before starts_on.
      assert [
               %{"code" => "invalid_period"}
             ] =
               json_response(
                 json_post(
                   conn,
                   close_period(%{
                     "operation_id" => "before-start",
                     "period_end_on" => "2026-09-30"
                   })
                 ),
                 200
               )["results"]

      # Missing or invalid dates.
      for {index, bad} <- Enum.with_index([nil, "nope", "2026-13-40", 20_261_130]) do
        operation_id = "bad-#{index}"

        bad_op =
          Map.merge(
            close_period(%{"operation_id" => operation_id}),
            if(bad == nil, do: %{}, else: %{"period_end_on" => bad})
          )
          |> maybe_delete_bad(bad)

        assert [
                 %{
                   "operation_id" => ^operation_id,
                   "status" => "rejected",
                   "code" => "invalid_period"
                 }
               ] = json_response(json_post(conn, bad_op), 200)["results"]
      end

      # Nothing closed, so reports through starts_on remain open.
      assert daily_report(conn, "2026-10-01")["status"] == "open"
    end

    test "a close not later than the latest cutoff is rejected", %{conn: conn} do
      json_post(conn, start_reporting())
      json_post(conn, close_period(%{"operation_id" => "close-1"}))

      for {operation_id, period} <- [{"same", "2026-11-30"}, {"earlier", "2026-11-01"}] do
        assert [
                 %{
                   "operation_id" => ^operation_id,
                   "status" => "rejected",
                   "code" => "invalid_period"
                 }
               ] =
                 json_response(
                   json_post(
                     conn,
                     close_period(%{"operation_id" => operation_id, "period_end_on" => period})
                   ),
                   200
                 )["results"]
      end

      # A later one still applies.
      assert [
               %{
                 "operation_id" => "later",
                 "status" => "applied",
                 "period_end_on" => "2026-12-31"
               }
             ] =
               json_response(
                 json_post(
                   conn,
                   close_period(%{"operation_id" => "later", "period_end_on" => "2026-12-31"})
                 ),
                 200
               )["results"]
    end

    test "closes replay durably and rejections are remembered", %{conn: conn} do
      json_post(conn, start_reporting())
      json_post(conn, close_period())

      # An exact retry returns the exact stored result without touching state.
      stored = json_response(json_post(conn, close_period()), 200)

      assert stored == %{
               "results" => [
                 %{
                   "operation_id" => "op-close",
                   "status" => "applied",
                   "period_end_on" => "2026-11-30"
                 }
               ]
             }

      # A different operation attempting the same cutoff is rejected, and
      # that rejection replays exactly.
      rival = close_period(%{"operation_id" => "rival"})
      [rejection] = json_response(json_post(conn, rival), 200)["results"]

      assert Map.take(rejection, ["operation_id", "status", "code"]) == %{
               "operation_id" => "rival",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert [^rejection] = json_response(json_post(conn, rival), 200)["results"]

      # Reusing the original identifier with a different payload conflicts.
      assert [
               %{
                 "operation_id" => "op-close",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] =
               json_response(
                 json_post(conn, close_period(%{"period_end_on" => "2026-12-31"})),
                 200
               )["results"]
    end
  end

  describe "posting after a close" do
    test "old-dated operations post on the first open day as late adjustments", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)
      json_post(conn, close_period())

      conn =
        json_post(
          conn,
          payment(%{
            "operation_id" => "pay-old",
            "occurred_on" => "2026-11-25",
            "amount_cents" => 5_000
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      open_day = daily_report(conn, "2026-12-01")

      assert open_day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 5_000
               }
             ]

      assert open_day["late_adjustments"] ==
               late_adjustments(%{
                 "cash" => [ams_late(cash_movements(%{"received_cents" => 5_000}))]
               })

      # The closed day reports were not touched.
      assert daily_report(conn, "2026-11-25")["cash"] == []
      assert daily_report(conn, "2026-11-25")["status"] == "closed"
    end

    test "operations whose date is already open keep it and report ordinary movements", %{
      conn: conn
    } do
      json_post(conn, start_reporting())
      open_group!(conn)
      json_post(conn, close_period())

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-open",
          "occurred_on" => "2026-12-05",
          "amount_cents" => 5_000
        })
      )

      assert daily_report(conn, "2026-12-05")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 5_000
               }
             ]

      assert daily_report(conn, "2026-12-05")["late_adjustments"] == late_adjustments()
    end

    test "a later close never moves a committed posting", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)
      json_post(conn, close_period())

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-old",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 5_000
        })
      )

      before = daily_report(conn, "2026-12-01")
      assert before["status"] == "open"

      assert before["late_adjustments"]["cash"] == [
               ams_late(cash_movements(%{"received_cents" => 5_000}))
             ]

      json_post(
        conn,
        close_period(%{"operation_id" => "close-2", "period_end_on" => "2026-12-31"})
      )

      later = daily_report(conn, "2026-12-01")
      assert later["status"] == "closed"
      assert Map.delete(later, "status") == Map.delete(before, "status")

      # The movement stayed on 2026-12-01 and was not pushed again.
      assert daily_report(conn, "2027-01-01")["late_adjustments"] == late_adjustments()
    end

    test "an operation before a close in the same batch posts into the period being closed", %{
      conn: conn
    } do
      json_post(conn, start_reporting())
      open_group!(conn)

      conn =
        submit(conn, [
          payment(%{
            "operation_id" => "pay-before",
            "occurred_on" => "2026-11-25",
            "amount_cents" => 5_000
          }),
          close_period(%{"operation_id" => "close-1", "period_end_on" => "2026-11-30"})
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) == [
               "applied",
               "applied"
             ]

      day = daily_report(conn, "2026-11-25")
      assert day["status"] == "closed"

      assert day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 5_000
               }
             ]

      assert day["late_adjustments"] == late_adjustments()
    end

    test "an old-dated operation after a close in the same batch posts on the first open day", %{
      conn: conn
    } do
      json_post(conn, start_reporting())
      open_group!(conn)

      # Close the first half, then a later close within one batch.
      json_post(
        conn,
        close_period(%{"operation_id" => "close-1", "period_end_on" => "2026-10-31"})
      )

      conn =
        submit(conn, [
          close_period(%{"operation_id" => "close-2", "period_end_on" => "2026-11-30"}),
          payment(%{
            "operation_id" => "pay-after",
            "occurred_on" => "2026-11-25",
            "amount_cents" => 4_000
          })
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) == [
               "applied",
               "applied"
             ]

      assert daily_report(conn, "2026-12-01")["late_adjustments"] ==
               late_adjustments(%{
                 "cash" => [ams_late(cash_movements(%{"received_cents" => 4_000}))]
               })
    end

    test "a day's totals are its ordinary movements plus its late adjustments", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)
      json_post(conn, close_period())

      conn =
        submit(conn, [
          payment(%{
            "operation_id" => "pay-open",
            "occurred_on" => "2026-12-01",
            "amount_cents" => 3_000
          }),
          payment(%{
            "operation_id" => "pay-old",
            "occurred_on" => "2026-11-25",
            "amount_cents" => 2_000
          })
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) == [
               "applied",
               "applied"
             ]

      day = daily_report(conn, "2026-12-01")

      # Ordinary columns show only the movement that naturally posts here.
      assert day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 3_000}),
                 "closing_held_cents" => 5_000
               }
             ]

      # The close-moved movement is separated out but still counts toward
      # the closing balance.
      assert day["late_adjustments"] ==
               late_adjustments(%{
                 "cash" => [ams_late(cash_movements(%{"received_cents" => 2_000}))]
               })
    end
  end

  describe "late adjustments" do
    test "a post-close chargeback shows its signed reclassifications", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 100
        })
      )

      json_post(conn, cancel(%{"operation_id" => "cancel-1", "occurred_on" => "2026-11-20"}))

      json_post(conn, close_period())

      json_post(
        conn,
        charge_back(%{
          "operation_id" => "charge-1",
          "payment_operation_id" => "pay-1",
          "occurred_on" => "2026-11-25"
        })
      )

      open_day = daily_report(conn, "2026-12-01")

      assert open_day["late_adjustments"] ==
               late_adjustments(%{
                 "cash" => [
                   ams_late(
                     cash_movements(%{"refunded_cents" => -100, "charged_back_cents" => 100})
                   )
                 ]
               })

      # The signed classifications survive even though their net is zero.
      assert open_day["cash"] == []

      # The day the refund reported stays byte-for-byte stable.
      closed_day = daily_report(conn, "2026-11-20")
      assert closed_day["status"] == "closed"

      assert closed_day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 100,
                 "movements" => cash_movements(%{"refunded_cents" => 100}),
                 "closing_held_cents" => 0
               }
             ]

      assert closed_day["late_adjustments"] == late_adjustments()
    end

    test "late cash entries are ordered by property and omit all-zero properties", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      submit(conn, [
        open_group(%{
          "operation_id" => "open-92",
          "group_id" => "group-92",
          "guest_id" => "guest-22",
          "property_id" => "utr-central"
        })
      ])

      json_post(conn, close_period())

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-a",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 3_000
        })
      )

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-b",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-26",
          "amount_cents" => 2_000
        })
      )

      late = daily_report(conn, "2026-12-01")["late_adjustments"]

      assert Enum.map(late["cash"], & &1["property_id"]) == ["ams-canal", "utr-central"]

      assert late["cash"] == [
               ams_late(cash_movements(%{"received_cents" => 3_000})),
               %{
                 "property_id" => "utr-central",
                 "movements" => cash_movements(%{"received_cents" => 2_000})
               }
             ]

      assert late["credit"] == credit_movements()
    end

    test "late non-refundable settlement reports the consumption as a credit adjustment", %{
      conn: conn
    } do
      json_post(conn, start_reporting())
      issue_lot(conn)

      submit(conn, [
        open_group(%{
          "operation_id" => "open-adv",
          "group_id" => "group-adv",
          "guest_id" => "guest-22",
          "rate_plan" => "advance_purchase"
        })
      ])

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-1",
          "group_id" => "group-adv",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 5_000
        })
      )

      json_post(conn, close_period())

      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-adv",
          "group_id" => "group-adv",
          "occurred_on" => "2026-11-26"
        })
      )

      open_day = daily_report(conn, "2026-12-01")

      assert open_day["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => credit_movements(),
               "closing_liability_cents" => 6_000
             }

      assert open_day["late_adjustments"] ==
               late_adjustments(%{"credit" => credit_movements(%{"consumed_cents" => 5_000})})

      # The ledger still restricts liability for the consumed credit.
      assert json_response(get(conn, "/api/v1/ledger?on=2026-12-01"), 200)["data"][
               "credit_liability_cents"
             ] == 6_000
    end

    test "a late hotel-credit conversion reports its cash and issued liability as late", %{
      conn: conn
    } do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 10_000
        })
      )

      json_post(conn, close_period())

      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-1",
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      )

      open_day = daily_report(conn, "2026-12-01")

      assert open_day["late_adjustments"] ==
               late_adjustments(%{
                 "cash" => [ams_late(cash_movements(%{"converted_to_credit_cents" => 10_000}))],
                 "credit" => credit_movements(%{"issued_cents" => 11_000})
               })

      assert open_day["credit"]["closing_liability_cents"] == 11_000
    end

    test "closed-day data survives later operations and later closes", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 5_000
        })
      )

      before_close = daily_report(conn, "2026-11-01")
      assert before_close["status"] == "open"

      json_post(conn, close_period())

      closed = daily_report(conn, "2026-11-01")
      assert closed["status"] == "closed"
      assert Map.delete(closed, "status") == Map.delete(before_close, "status")

      # Later work in the open period cannot rewrite the closed day.
      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-2",
          "occurred_on" => "2026-12-05",
          "amount_cents" => 3_000
        })
      )

      json_post(
        conn,
        close_period(%{"operation_id" => "close-2", "period_end_on" => "2026-12-31"})
      )

      assert daily_report(conn, "2026-11-01") == closed
    end
  end

  # Opens a group for the guest, pays 10_000, and cancels it with hotel
  # credit so the guest owns an 11_000 lot.
  defp issue_lot(conn) do
    submit(conn, [
      open_group(%{"operation_id" => "open-src", "group_id" => "group-src"}),
      payment(%{
        "operation_id" => "pay-src",
        "group_id" => "group-src",
        "occurred_on" => "2026-11-01",
        "amount_cents" => 10_000
      }),
      cancel(%{
        "operation_id" => "cancel-src",
        "group_id" => "group-src",
        "occurred_on" => "2026-11-20",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp maybe_delete_bad(op, nil), do: Map.delete(op, "period_end_on")
  defp maybe_delete_bad(op, _bad), do: op
end
