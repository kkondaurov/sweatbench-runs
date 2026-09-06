defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  # The default group holds deposits at ams-canal; the companion group at
  # lon-thames. Reporting starts on 2026-11-01.

  @zero_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @zero_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  describe "closing through a date" do
    setup :started_default_group

    test "the applied result contains exactly the three documented fields", %{conn: conn} do
      assert [result] = run_batch(conn, [close_op("op-close", "2026-11-10")])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-11-10"
             }
    end

    test "a retry of an applied close replays its exact stored result", %{conn: conn} do
      assert [first] = run_batch(conn, [close_op("op-close", "2026-11-10")])
      assert [replay] = run_batch(conn, [close_op("op-close", "2026-11-10")])
      assert replay == first
    end

    test "a different operation attempting the same or an earlier cutoff is rejected", %{
      conn: conn
    } do
      run_batch(conn, [close_op("op-close", "2026-11-10")])

      for {op_id, cutoff} <- [
            {"op-close-same", "2026-11-10"},
            {"op-close-earlier", "2026-11-09"}
          ] do
        assert [%{"status" => "rejected", "code" => "invalid_period"}] =
                 run_batch(conn, [close_op(op_id, cutoff)])
      end

      # Nothing was closed again, so a later close still applies.
      assert [%{"status" => "applied"}] = run_batch(conn, [close_op("op-close-2", "2026-11-15")])
    end

    test "reports through period_end_on are closed and later reports are open", %{conn: conn} do
      run_batch(conn, [
        payment_operation("op-pay", 12_000) |> Map.put("occurred_on", "2026-11-05")
      ])

      run_batch(conn, [close_op("op-close", "2026-11-10")])

      assert %{"data" => %{"status" => "closed"}} =
               conn |> get_report("?date=2026-11-01") |> json_response(200)

      assert %{"data" => %{"status" => "closed"}} =
               conn |> get_report("?date=2026-11-10") |> json_response(200)

      assert %{"data" => %{"status" => "open"}} =
               conn |> get_report("?date=2026-11-11") |> json_response(200)
    end
  end

  describe "closing without reporting" do
    test "a close before reporting starts, before starts_on, or with a bad date is rejected", %{
      conn: conn
    } do
      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               run_batch(conn, [close_op("op-early", "2026-11-10")])

      open_default_group(conn)
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      results =
        run_batch(conn, [
          close_op("op-before-start", "2026-10-31"),
          close_op("op-bad-date", "not-a-date"),
          close_op("op-missing-date", "2026-11-05") |> Map.delete("period_end_on")
        ])

      assert Enum.all?(results, &(&1["code"] == "invalid_period"))

      assert [%{"status" => "applied"}] = run_batch(conn, [close_op("op-good", "2026-11-01")])
    end
  end

  describe "posting after a close" do
    setup :started_default_group

    test "an old-dated operation after a close posts on the first open day as a late adjustment",
         %{
           conn: conn
         } do
      run_batch(conn, [
        payment_operation("op-pay", 12_000) |> Map.put("occurred_on", "2026-11-05")
      ])

      run_batch(conn, [close_op("op-close", "2026-11-10")])

      run_batch(conn, [
        payment_operation("op-late", 3_000) |> Map.put("occurred_on", "2026-11-07")
      ])

      assert %{"data" => report} =
               conn |> get_report("?date=2026-11-11") |> json_response(200)

      assert report["status"] == "open"

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 12_000,
                 "movements" => @zero_cash_movements,
                 "closing_held_cents" => 15_000
               }
             ]

      assert report["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{@zero_cash_movements | "received_cents" => 3_000}
                 }
               ],
               "credit" => @zero_credit_movements
             }

      # The operation keeps its posting date; later days carry it forward
      # without new movements or late adjustments.
      assert %{
               "data" => %{
                 "cash" => [
                   %{"opening_held_cents" => 15_000, "movements" => @zero_cash_movements}
                 ],
                 "late_adjustments" => %{"cash" => [], "credit" => @zero_credit_movements}
               }
             } =
               conn |> get_report("?date=2026-11-12") |> json_response(200)
    end

    test "an operation already dated in the open period keeps that date", %{conn: conn} do
      run_batch(conn, [close_op("op-close", "2026-11-10")])

      run_batch(conn, [
        payment_operation("op-open-day", 4_000) |> Map.put("occurred_on", "2026-11-14")
      ])

      assert %{"data" => %{"cash" => [%{"movements" => mov}], "late_adjustments" => late}} =
               conn |> get_report("?date=2026-11-14") |> json_response(200)

      assert mov["received_cents"] == 4_000
      assert late == %{"cash" => [], "credit" => @zero_credit_movements}
    end

    test "an operation immediately before a close can post into the period being closed", %{
      conn: conn
    } do
      assert [_, _, _] =
               results =
               run_batch(conn, [
                 payment_operation("op-pay", 5_000) |> Map.put("occurred_on", "2026-11-20"),
                 close_op("op-close", "2026-11-20"),
                 payment_operation("op-after", 2_000) |> Map.put("occurred_on", "2026-11-19")
               ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied)

      # The earlier payment posts inside the closed period on its own day.
      assert %{"data" => %{"status" => "closed", "cash" => [%{"movements" => mov}]}} =
               conn |> get_report("?date=2026-11-20") |> json_response(200)

      assert mov["received_cents"] == 5_000

      # The old-dated operation right after the close posts on the next day.
      assert %{
               "data" => %{
                 "late_adjustments" => %{"cash" => [entry], "credit" => credit}
               }
             } =
               conn |> get_report("?date=2026-11-21") |> json_response(200)

      assert entry["property_id"] == "ams-canal"
      assert entry["movements"]["received_cents"] == 2_000
      assert credit == @zero_credit_movements
    end

    test "later closes never move a committed posting date", %{conn: conn} do
      run_batch(conn, [close_op("op-close-1", "2026-11-10")])

      run_batch(conn, [
        payment_operation("op-late", 3_000) |> Map.put("occurred_on", "2026-11-07")
      ])

      before =
        conn |> get_report("?date=2026-11-11") |> json_response(200) |> Map.fetch!("data")

      run_batch(conn, [close_op("op-close-2", "2026-11-15")])

      run_batch(conn, [
        payment_operation("op-more", 1_000) |> Map.put("occurred_on", "2026-11-03")
      ])

      after_more =
        conn |> get_report("?date=2026-11-11") |> json_response(200) |> Map.fetch!("data")

      # The report's figures are unchanged; only its publication status follows
      # the newer close.
      assert Map.delete(after_more, "status") == Map.delete(before, "status")
      assert before["status"] == "open"
      assert after_more["status"] == "closed"

      # The newer old-dated operation lands on the first open day of the newest
      # close; both late adjustments sit on their own days.
      assert %{"data" => %{"late_adjustments" => %{"cash" => [only]}}} =
               conn |> get_report("?date=2026-11-16") |> json_response(200)

      assert only["movements"]["received_cents"] == 1_000
    end

    test "closed reports stay byte-for-byte stable across later operations", %{conn: conn} do
      run_batch(conn, [
        open_companion_group_operation(),
        payment_operation("op-pay", 12_000) |> Map.put("occurred_on", "2026-11-05"),
        transfer_op("op-xfer", "group-81", "group-92", 5_000, "2026-11-08"),
        cancel_op("op-cancel", "2026-11-09")
      ])

      run_batch(conn, [close_op("op-close", "2026-11-10")])

      closed_days = Date.range(~D[2026-11-01], ~D[2026-11-10])

      before =
        Map.new(closed_days, fn date ->
          {date, conn |> get_report("?date=#{Date.to_iso8601(date)}") |> json_response(200)}
        end)

      run_batch(conn, [
        charge_back_op("op-chb", "op-pay", "2026-11-07"),
        payment_operation("op-pay-2", 1_500) |> Map.put("occurred_on", "2026-11-02")
      ])

      after_operations =
        Map.new(closed_days, fn date ->
          {date, conn |> get_report("?date=#{Date.to_iso8601(date)}") |> json_response(200)}
        end)

      assert after_operations == before
    end
  end

  describe "identifying late adjustments" do
    setup :started_default_group

    test "signed classifications survive even when the net balance effect is zero", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 100) |> Map.put("occurred_on", "2026-11-05")])

      run_batch(conn, [
        cancel_op("op-cancel", "2026-11-06"),
        close_op("op-close", "2026-11-10"),
        charge_back_op("op-chb", "op-pay", "2026-11-08")
      ])

      assert %{"data" => report} =
               conn |> get_report("?date=2026-11-11") |> json_response(200)

      assert report["cash"] == []

      assert report["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{
                     @zero_cash_movements
                     | "refunded_cents" => -100,
                       "charged_back_cents" => 100
                   }
                 }
               ],
               "credit" => @zero_credit_movements
             }

      # The closing balance effect nets to zero, so no cash entry appears.
      assert %{"data" => %{"cash" => []}} =
               conn |> get_report("?date=2026-11-12") |> json_response(200)
    end

    test "late adjustments across properties are ordered by property_id", %{conn: conn} do
      run_batch(conn, [
        open_companion_group_operation(),
        payment_operation("op-pay", 8_000) |> Map.put("occurred_on", "2026-11-04")
      ])

      run_batch(conn, [close_op("op-close", "2026-11-10")])

      run_batch(conn, [
        transfer_op("op-xfer", "group-81", "group-92", 3_000, "2026-11-06")
      ])

      assert %{
               "data" => %{
                 "cash" => [ams, lon],
                 "late_adjustments" => %{"cash" => [la_ams, la_lon]}
               }
             } =
               conn |> get_report("?date=2026-11-11") |> json_response(200)

      assert ams["property_id"] == "ams-canal"
      assert ams["opening_held_cents"] == 8_000
      assert ams["movements"] == @zero_cash_movements
      assert ams["closing_held_cents"] == 5_000

      assert lon["property_id"] == "lon-thames"
      assert lon["opening_held_cents"] == 0
      assert lon["closing_held_cents"] == 3_000

      assert la_ams["property_id"] == "ams-canal"
      assert la_ams["movements"]["transferred_out_cents"] == 3_000

      assert la_lon["property_id"] == "lon-thames"
      assert la_lon["movements"]["transferred_in_cents"] == 3_000
    end

    test "revoked credit moved by a close appears in the credit late adjustments", %{conn: conn} do
      run_batch(conn, [
        payment_operation("op-pay", 12_000) |> Map.put("occurred_on", "2026-11-05"),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "refund_method" => "hotel_credit"
        }
      ])

      run_batch(conn, [close_op("op-close", "2026-11-25")])

      run_batch(conn, [charge_back_op("op-chb", "op-pay", "2026-11-24")])

      assert %{"data" => report} =
               conn |> get_report("?date=2026-11-26") |> json_response(200)

      # Both cash reversals were moved onto the first open day, so they appear
      # as signed late adjustments; the balance effect nets to zero.
      assert report["cash"] == []

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   @zero_cash_movements
                   | "converted_to_credit_cents" => -12_000,
                     "charged_back_cents" => 12_000
                 }
               }
             ]

      # The unspent entitlement's revocation is a credit late adjustment.
      assert report["late_adjustments"]["credit"] == %{
               @zero_credit_movements
               | "revoked_cents" => 13_200
             }
    end

    test "ordinary movements and late adjustments sum into the day's totals", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 6_000) |> Map.put("occurred_on", "2026-11-05")])

      run_batch(conn, [close_op("op-close", "2026-11-10")])

      run_batch(conn, [
        payment_operation("op-late", 2_000) |> Map.put("occurred_on", "2026-11-08"),
        payment_operation("op-normal", 3_000) |> Map.put("occurred_on", "2026-11-11")
      ])

      assert %{"data" => %{"cash" => [entry]}} =
               conn |> get_report("?date=2026-11-11") |> json_response(200)

      assert entry["opening_held_cents"] == 6_000
      assert entry["movements"]["received_cents"] == 3_000
      assert entry["closing_held_cents"] == 11_000
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp started_default_group(%{conn: conn}) do
    open_default_group(conn)
    run_batch(conn, [start_op("op-fin", starts_on())])
    %{conn: conn}
  end

  defp open_default_group(conn),
    do: assert([%{"status" => "applied"}] = run_batch(conn, [open_operation()]))

  defp open_companion_group_operation do
    open_operation(
      operation_id: "op-open-b",
      group_id: "group-92",
      property_id: "lon-thames",
      rooms: [%{"room_id" => "room-c", "nightly_rate_cents" => 10_000}]
    )
  end

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp get_report(conn, query) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/finance/daily-report" <> query,
      nil
    )
  end

  defp starts_on, do: "2026-11-01"

  defp start_op(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_op(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp payment_operation(operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(operation_id, source_group_id, destination_group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-81"
    }
  end

  defp charge_back_op(operation_id, target_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => target_id
    }
  end
end
