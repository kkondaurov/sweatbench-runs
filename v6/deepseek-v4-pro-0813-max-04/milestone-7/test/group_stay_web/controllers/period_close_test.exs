defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_report(conn, date), do: get(conn, "/api/v1/finance/daily-report", %{"date" => date})

  defp report(conn, date), do: json_response(get_report(conn, date), 200)["data"]

  defp report_body(conn, date), do: response(get_report(conn, date), 200)

  defp cash_of(report, property_id),
    do: Enum.find(report["cash"], &(&1["property_id"] == property_id))

  defp late_cash_of(report, property_id),
    do: Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))

  defp movements_of(entry), do: entry["movements"]

  defp start(conn, starts_on \\ "2026-10-01") do
    batch_results(conn, [start_finance_reporting(%{"starts_on" => starts_on})])
  end

  describe "closing a period" do
    test "returns exactly operation_id, status, and period_end_on" do
      conn = build_conn()
      start(conn)

      results = batch_results(conn, [close_finance_period()])

      assert results == [
               %{
                 "operation_id" => "op-close-period",
                 "status" => "applied",
                 "period_end_on" => "2026-10-20"
               }
             ]
    end

    test "rejects with invalid_period before reporting started" do
      conn = build_conn()

      assert batch_results(conn, [close_finance_period()]) == [
               %{
                 "operation_id" => "op-close-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
    end

    test "rejects a cutoff before starts_on" do
      conn = build_conn()
      start(conn, "2026-10-01")

      early = close_finance_period(%{"period_end_on" => "2026-09-30"})
      assert batch_results(conn, [early]) |> hd() |> Map.get("code") == "invalid_period"
    end

    test "accepts a cutoff equal to starts_on and then only strictly later ones" do
      conn = build_conn()
      start(conn, "2026-10-01")

      first = close_finance_period(%{"period_end_on" => "2026-10-01"})
      same = close_finance_period(%{"operation_id" => "op-close-same"})
      # same cutoff is not strictly later than the latest close
      assert Enum.at(batch_results(conn, [first]), 0) |> Map.get("status") == "applied"

      assert batch_results(conn, [%{same | "period_end_on" => "2026-10-01"}])
             |> hd()
             |> Map.get("code") == "invalid_period"

      earlier = close_finance_period(%{"operation_id" => "op-close-earlier"})

      assert batch_results(conn, [%{earlier | "period_end_on" => "2026-09-30"}])
             |> hd()
             |> Map.get("code") == "invalid_period"

      later = close_finance_period(%{"operation_id" => "op-close-later"})

      assert batch_results(conn, [%{later | "period_end_on" => "2026-10-20"}])
             |> hd()
             |> Map.get("status") == "applied"
    end

    test "rejects a missing or unusable period_end_on" do
      conn = build_conn()
      start(conn)

      missing =
        Map.delete(close_finance_period(%{"operation_id" => "op-no-cutoff"}), "period_end_on")

      bad =
        close_finance_period(%{
          "operation_id" => "op-bad-cutoff",
          "period_end_on" => "not-a-date"
        })

      results = batch_results(conn, [missing, bad])

      assert Enum.map(results, & &1["code"]) == ["invalid_period", "invalid_period"]
      assert report(conn, "2026-10-01")["status"] == "open"
    end

    test "replays the stored result and conflicts on a different payload" do
      conn = build_conn()
      start(conn)

      close = close_finance_period()

      assert batch_results(conn, [close]) == batch_results(conn, [close])

      conflict = close_finance_period(%{"period_end_on" => "2026-10-21"})

      assert batch_results(conn, [conflict]) == [
               %{
                 "operation_id" => "op-close-period",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]

      assert json_response(
               get(conn, "/api/v1/operations/op-close-period"),
               200
             )["data"] ==
               %{
                 "operation_id" => "op-close-period",
                 "status" => "applied",
                 "period_end_on" => "2026-10-20"
               }
    end

    test "a stored close rejection replays even after it would become valid" do
      conn = build_conn()

      rejected = close_finance_period()

      assert batch_results(conn, [rejected]) |> hd() == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      # Reporting starts later, which would make this cutoff valid, but the
      # durable rejection is remembered verbatim.
      start(conn)

      assert batch_results(conn, [rejected]) |> hd() == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      fresh = close_finance_period(%{"operation_id" => "op-close-fresh"})
      assert batch_results(conn, [fresh]) |> hd() |> Map.get("status") == "applied"
    end
  end

  describe "published reports" do
    test "reports through the cutoff are closed and later reports are open" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{"occurred_on" => "2026-10-02", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-05"})
      ])

      for date <- ["2026-10-01", "2026-10-02", "2026-10-05"] do
        assert report(conn, date)["status"] == "closed"
      end

      assert report(conn, "2026-10-06")["status"] == "open"
      assert report(conn, "2027-01-01")["status"] == "open"
    end

    test "closed reports stay byte-for-byte stable across later operations and closes" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        open(%{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "bcn-plaza"
        }),
        payment(%{"occurred_on" => "2026-10-02", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-05"})
      ])

      frozen = report_body(conn, "2026-10-02")

      # Later operations post on the first open day and never touch 10-02.
      batch_results(conn, [
        cancel(%{"occurred_on" => "2026-10-04"}),
        payment(%{
          "operation_id" => "op-pay-late",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 1_000
        })
      ])

      assert report_body(conn, "2026-10-02") == frozen

      # A second close also leaves every earlier published report untouched.
      quiet = report_body(conn, "2026-10-03")

      batch_results(conn, [
        close_finance_period(%{"operation_id" => "op-close-2", "period_end_on" => "2026-10-10"})
      ])

      assert report_body(conn, "2026-10-02") == frozen
      assert report_body(conn, "2026-10-03") == quiet
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts on the first open day as a late adjustment" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{"occurred_on" => "2026-10-05", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-10"}),
        payment(%{
          "operation_id" => "op-pay-old",
          "occurred_on" => "2026-10-09",
          "amount_cents" => 2_000
        }),
        payment(%{
          "operation_id" => "op-pay-current",
          "occurred_on" => "2026-10-12",
          "amount_cents" => 1_000
        })
      ])

      old_day = report(conn, "2026-10-09")
      assert old_day["status"] == "closed"

      moved_day = cash_of(report(conn, "2026-10-11"), "ams-canal")
      assert movements_of(moved_day)["received_cents"] == 0

      assert late_cash_of(report(conn, "2026-10-11"), "ams-canal")["movements"][
               "received_cents"
             ] == 2_000

      assert moved_day["opening_held_cents"] == 4_000
      assert moved_day["closing_held_cents"] == 6_000

      on_time = cash_of(report(conn, "2026-10-12"), "ams-canal")
      assert movements_of(on_time)["received_cents"] == 1_000
      assert late_cash_of(report(conn, "2026-10-12"), "ams-canal") == nil
      assert on_time["opening_held_cents"] == 6_000
      assert on_time["closing_held_cents"] == 7_000
    end

    test "an operation immediately before a close posts into the closed period" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{
          "operation_id" => "op-pay-before",
          "occurred_on" => "2026-10-09",
          "amount_cents" => 4_000
        }),
        close_finance_period(%{"period_end_on" => "2026-10-10"}),
        payment(%{
          "operation_id" => "op-pay-after",
          "occurred_on" => "2026-10-09",
          "amount_cents" => 2_000
        })
      ])

      closed_day = cash_of(report(conn, "2026-10-09"), "ams-canal")
      assert movements_of(closed_day)["received_cents"] == 4_000
      assert report(conn, "2026-10-09")["status"] == "closed"

      open_day = report(conn, "2026-10-11")
      assert movements_of(cash_of(open_day, "ams-canal"))["received_cents"] == 0

      assert late_cash_of(open_day, "ams-canal")["movements"]["received_cents"] == 2_000
    end

    test "a later close never moves an operation's chosen posting date" do
      conn = build_conn()

      late_payment = %{
        "operation_id" => "op-pay-old",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-09",
        "group_id" => "group-81",
        "amount_cents" => 2_000
      }

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{"occurred_on" => "2026-10-05", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-10"}),
        late_payment
      ])

      before = report(conn, "2026-10-11")

      batch_results(conn, [
        close_finance_period(%{"operation_id" => "op-close-2", "period_end_on" => "2026-10-15"})
      ])

      # Publishing 10-11 does not move its movement again: the late movement
      # still posts there, and the first open day of the new period is empty.
      published = report(conn, "2026-10-11")
      assert published["status"] == "closed"
      assert published["late_adjustments"] == before["late_adjustments"]

      next_day = cash_of(report(conn, "2026-10-16"), "ams-canal")
      assert movements_of(next_day)["received_cents"] == 0
      assert next_day["opening_held_cents"] == 6_000
    end
  end

  describe "late adjustments" do
    test "the block contains only moved movements and the credit object is always present" do
      conn = build_conn()
      open_a = open()

      open_b =
        open(%{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "bcn-plaza"
        })

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open_a,
        open_b,
        open(%{
          "operation_id" => "op-open-empty",
          "group_id" => "group-empty",
          "property_id" => "zzz-empty"
        }),
        payment(%{"occurred_on" => "2026-10-02", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-10"}),
        payment(%{
          "operation_id" => "op-pay-old-a",
          "occurred_on" => "2026-10-03",
          "amount_cents" => 1_000
        }),
        payment(%{
          "operation_id" => "op-pay-old-b",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-03",
          "amount_cents" => 500
        })
      ])

      day = report(conn, "2026-10-11")
      late = day["late_adjustments"]

      assert late["credit"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert Enum.map(late["cash"], & &1["property_id"]) == ["ams-canal", "bcn-plaza"]

      ams = late_cash_of(day, "ams-canal")

      assert ams["movements"] == %{
               "received_cents" => 1_000,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      bcn = late_cash_of(day, "bcn-plaza")
      assert bcn["movements"]["received_cents"] == 500
    end

    test "reports signed chargeback reversals rather than a zero-net adjustment" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{"occurred_on" => "2026-10-02", "amount_cents" => 100}),
        cancel(%{"occurred_on" => "2026-10-02"}),
        close_finance_period(%{"period_end_on" => "2026-10-05"}),
        charge_back(%{"occurred_on" => "2026-10-04"})
      ])

      day = report(conn, "2026-10-06")

      assert cash_of(day, "ams-canal")["movements"] == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert late_cash_of(day, "ams-canal")["movements"] == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => -100,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 100
             }
    end

    test "late credit effects appear in the credit object" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{"occurred_on" => "2026-10-02", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-05"}),
        cancel(%{"occurred_on" => "2026-10-04", "refund_method" => "hotel_credit"})
      ])

      day = report(conn, "2026-10-06")

      assert late_cash_of(day, "ams-canal")["movements"]["converted_to_credit_cents"] == 4_000

      assert day["late_adjustments"]["credit"] == %{
               "issued_cents" => 4_400,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert day["credit"]["movements"]["issued_cents"] == 0
      assert day["credit"]["closing_liability_cents"] == 4_400
    end

    test "a rejected operation records no late movement and a retry does not double it" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        open(),
        payment(%{"occurred_on" => "2026-10-05", "amount_cents" => 4_000}),
        close_finance_period(%{"period_end_on" => "2026-10-10"}),
        payment(%{
          "operation_id" => "op-over-old",
          "occurred_on" => "2026-10-09",
          "amount_cents" => 99_999
        })
      ])

      day = report(conn, "2026-10-11")
      assert late_cash_of(day, "ams-canal") == nil

      batch_results(conn, [
        payment(%{
          "operation_id" => "op-pay-old",
          "occurred_on" => "2026-10-09",
          "amount_cents" => 1_000
        })
      ])

      before = report_body(conn, "2026-10-11")

      batch_results(conn, [
        payment(%{
          "operation_id" => "op-pay-old",
          "occurred_on" => "2026-10-09",
          "amount_cents" => 1_000
        })
      ])

      assert report_body(conn, "2026-10-11") == before

      assert late_cash_of(report(conn, "2026-10-11"), "ams-canal")["movements"]["received_cents"] ==
               1_000
    end
  end
end
