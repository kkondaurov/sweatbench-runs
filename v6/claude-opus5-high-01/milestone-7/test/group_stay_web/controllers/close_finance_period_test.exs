defmodule GroupStayWeb.CloseFinancePeriodTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.PartnerCase

  describe "close_finance_period" do
    setup %{conn: conn} do
      submit_one(conn, start_reporting_op(%{"starts_on" => "2026-10-04"}))
      :ok
    end

    test "returns only the operation, its status, and the cutoff", %{conn: conn} do
      assert submit_one(conn, close_period_op()) == %{
               "operation_id" => "op-close-period",
               "status" => "applied",
               "period_end_on" => "2026-10-31"
             }
    end

    test "does not need an occurred_on date", %{conn: conn} do
      assert %{"status" => "applied"} =
               submit_one(conn, Map.delete(close_period_op(), "occurred_on"))
    end

    test "closes through the day reporting started", %{conn: conn} do
      assert %{"status" => "applied"} =
               submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-04"}))
    end

    test "refuses a cutoff before reporting started", %{conn: conn} do
      assert submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-03"})) == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "refuses a missing or unusable cutoff", %{conn: conn} do
      for period_end_on <- [nil, "", "not-a-date", "2026-13-01", 20_261_031] do
        operation =
          close_period_op(%{"operation_id" => "op-#{inspect(period_end_on)}"})
          |> put_or_delete("period_end_on", period_end_on)

        assert %{"status" => "rejected", "code" => "invalid_period"} =
                 submit_one(conn, operation)
      end
    end

    test "refuses the same cutoff or an earlier one", %{conn: conn} do
      submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-31"}))

      for period_end_on <- ["2026-10-31", "2026-10-30", "2026-10-04"] do
        assert %{"status" => "rejected", "code" => "invalid_period"} =
                 submit_one(
                   conn,
                   close_period_op(%{
                     "operation_id" => "op-again-#{period_end_on}",
                     "period_end_on" => period_end_on
                   })
                 )
      end
    end

    test "accepts a cutoff strictly later than the last one", %{conn: conn} do
      submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-31"}))

      assert %{"status" => "applied", "period_end_on" => "2026-11-01"} =
               submit_one(
                 conn,
                 close_period_op(%{"operation_id" => "op-next", "period_end_on" => "2026-11-01"})
               )
    end

    test "replays the original result for a retry and refuses a changed payload", %{conn: conn} do
      applied = submit_one(conn, close_period_op())

      assert submit_one(conn, close_period_op()) == applied
      assert read_operation(conn, "op-close-period") == applied

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(conn, close_period_op(%{"period_end_on" => "2026-11-30"}))
    end

    test "remembers a refused close just like any other rejection", %{conn: conn} do
      submit_one(conn, close_period_op())

      rejection =
        submit_one(
          conn,
          close_period_op(%{"operation_id" => "op-late", "period_end_on" => "2026-10-05"})
        )

      assert read_operation(conn, "op-late") == rejection

      assert submit_one(
               conn,
               close_period_op(%{"operation_id" => "op-late", "period_end_on" => "2026-10-05"})
             ) == rejection
    end

    test "a refused close leaves the cutoff where it was", %{conn: conn} do
      submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-31"}))

      submit_one(
        conn,
        close_period_op(%{"operation_id" => "op-back", "period_end_on" => "2026-10-10"})
      )

      assert read_daily_report(conn, "2026-10-31")["status"] == "closed"
      assert read_daily_report(conn, "2026-11-01")["status"] == "open"
    end
  end

  describe "closing before reporting has started" do
    test "is refused as an invalid period", %{conn: conn} do
      assert submit_one(conn, close_period_op()) == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "leaves reporting unstarted", %{conn: conn} do
      submit_one(conn, close_period_op())

      assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "closes once reporting starts later in the same batch", %{conn: conn} do
      assert [%{"status" => "rejected"}, %{"status" => "applied"}, %{"status" => "applied"}] =
               submit(conn, [
                 close_period_op(%{"operation_id" => "op-too-early"}),
                 start_reporting_op(%{"starts_on" => "2026-10-04"}),
                 close_period_op()
               ])["results"]

      assert read_daily_report(conn, "2026-10-31")["status"] == "closed"
    end
  end

  defp put_or_delete(operation, key, nil), do: Map.delete(operation, key)
  defp put_or_delete(operation, key, value), do: Map.put(operation, key, value)
end
