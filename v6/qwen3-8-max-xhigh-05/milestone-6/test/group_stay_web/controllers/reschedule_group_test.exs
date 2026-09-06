defmodule GroupStayWeb.RescheduleGroupTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-3001",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  test "shifts arrival and departure by the same number of days", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [reschedule_op()])

    assert result == %{
             "operation_id" => "op-3001",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2026-12-20",
             "new_departure_on" => "2026-12-23",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-12-06",
             "revision" => 2
           }

    data = group_data(conn, "group-81")
    assert data["arrival_on"] == "2026-12-20"
    assert data["departure_on"] == "2026-12-23"
    assert data["lodging_total_cents"] == 97500
    assert data["deposit_due_cents"] == 19500
  end

  test "applies even when the stay is unchanged", %{conn: conn} do
    %{"results" => [result]} =
      submit_batch(conn, [reschedule_op(%{"new_arrival_on" => "2026-12-10"})])

    assert result["status"] == "applied"
    assert result["new_arrival_on"] == "2026-12-10"
    assert result["new_departure_on"] == "2026-12-13"
    assert result["revision"] == 2
  end

  test "rejects a new arrival that is not after the operation date", %{conn: conn} do
    same_day = reschedule_op(%{"new_arrival_on" => "2026-10-05"})
    earlier = reschedule_op(%{"operation_id" => "op-3002", "new_arrival_on" => "2026-10-04"})

    %{"results" => [first, second]} = submit_batch(conn, [same_day, earlier])

    assert first["status"] == "rejected"
    assert first["code"] == "invalid_stay"
    assert second["status"] == "rejected"
    assert second["code"] == "invalid_stay"

    assert group_data(conn, "group-81")["arrival_on"] == "2026-12-10"
  end

  test "rejects a new arrival that cannot be parsed", %{conn: conn} do
    %{"results" => [result]} =
      submit_batch(conn, [reschedule_op(%{"new_arrival_on" => "soon"})])

    assert result["status"] == "rejected"
    assert result["code"] == "invalid_stay"
  end

  test "rejects a reschedule missing its new arrival as invalid_operation", %{conn: conn} do
    %{"results" => [result]} =
      submit_batch(conn, [Map.delete(reschedule_op(), "new_arrival_on")])

    assert result["status"] == "rejected"
    assert result["code"] == "invalid_operation"
  end

  test "rejects a reschedule for a missing group", %{conn: conn} do
    %{"results" => [result]} =
      submit_batch(conn, [reschedule_op(%{"group_id" => "group-404"})])

    assert result["status"] == "rejected"
    assert result["code"] == "group_not_found"
  end

  test "rejects a reschedule for a cancelled group", %{conn: conn} do
    submit_batch(conn, [
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }
    ])

    %{"results" => [result]} = submit_batch(conn, [reschedule_op()])

    assert result["status"] == "rejected"
    assert result["code"] == "group_not_active"
  end

  test "rejects a stale revision before evaluating dates", %{conn: conn} do
    operation =
      reschedule_op(%{"new_arrival_on" => "2026-10-01"}) |> Map.put("expected_revision", 4)

    %{"results" => [result]} = submit_batch(conn, [operation])

    assert result == %{
             "operation_id" => "op-3001",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 4,
             "actual_revision" => 1
           }
  end

  test "a rejected reschedule leaves the group unchanged", %{conn: conn} do
    submit_batch(conn, [reschedule_op(%{"new_arrival_on" => "2026-10-01"})])

    data = group_data(conn, "group-81")
    assert data["revision"] == 1
    assert data["arrival_on"] == "2026-12-10"
    assert data["departure_on"] == "2026-12-13"
  end
end
