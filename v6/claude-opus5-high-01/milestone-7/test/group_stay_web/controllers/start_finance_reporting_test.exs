defmodule GroupStayWeb.StartFinanceReportingTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.PartnerCase

  describe "start_finance_reporting" do
    test "returns only the operation, its status, and the date it starts on", %{conn: conn} do
      result = submit_one(conn, start_reporting_op())

      assert result == %{
               "operation_id" => "op-start-reporting",
               "status" => "applied",
               "starts_on" => "2026-10-04"
             }
    end

    test "does not need an occurred_on date", %{conn: conn} do
      assert %{"status" => "applied"} =
               submit_one(conn, Map.delete(start_reporting_op(), "occurred_on"))
    end

    test "rejects a missing or unusable starts_on", %{conn: conn} do
      for starts_on <- [nil, "", "not-a-date", "2026-13-01", 20_261_004] do
        operation =
          start_reporting_op(%{"operation_id" => "op-#{inspect(starts_on)}"})
          |> put_or_delete("starts_on", starts_on)

        assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
                 submit_one(conn, operation)
      end
    end

    test "rejects a later start once reporting has begun", %{conn: conn} do
      submit_one(conn, start_reporting_op())

      assert submit_one(conn, start_reporting_op(%{"operation_id" => "op-again"})) == %{
               "operation_id" => "op-again",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      assert submit_one(
               conn,
               start_reporting_op(%{"operation_id" => "op-other", "starts_on" => "2026-11-01"})
             ) == %{
               "operation_id" => "op-other",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
    end

    test "keeps the first start date when a later start is refused", %{conn: conn} do
      submit_one(conn, start_reporting_op())

      submit_one(
        conn,
        start_reporting_op(%{"operation_id" => "op-other", "starts_on" => "2026-11-01"})
      )

      assert %{"error" => %{"code" => "report_not_available"}} =
               conn
               |> get("/api/v1/finance/daily-report?date=2026-10-03")
               |> json_response(404)

      assert %{"date" => "2026-10-04"} = read_daily_report(conn, "2026-10-04")
    end

    test "replays the original result for a retry and refuses a changed payload", %{conn: conn} do
      applied = submit_one(conn, start_reporting_op())

      assert submit_one(conn, start_reporting_op()) == applied
      assert read_operation(conn, "op-start-reporting") == applied

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(conn, start_reporting_op(%{"starts_on" => "2026-11-01"}))
    end

    test "remembers a rejected start just like any other rejection", %{conn: conn} do
      submit_one(conn, start_reporting_op())

      rejection = submit_one(conn, start_reporting_op(%{"operation_id" => "op-again"}))

      assert read_operation(conn, "op-again") == rejection
      assert submit_one(conn, start_reporting_op(%{"operation_id" => "op-again"})) == rejection
    end

    test "an unusable date is refused before the state of reporting is consulted", %{conn: conn} do
      submit_one(conn, start_reporting_op())

      assert %{"code" => "invalid_reporting_date"} =
               submit_one(
                 conn,
                 start_reporting_op(%{"operation_id" => "op-bad", "starts_on" => "soon"})
               )
    end
  end

  defp put_or_delete(operation, key, nil), do: Map.delete(operation, key)
  defp put_or_delete(operation, key, value), do: Map.put(operation, key, value)
end
