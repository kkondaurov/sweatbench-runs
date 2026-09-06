defmodule GroupStayWeb.RescheduleAndCancelTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  describe "reschedule_group" do
    test "shifts the departure date by the same number of days", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, reschedule())

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-reschedule",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2027-01-04",
                   "new_departure_on" => "2027-01-07",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-21",
                   "revision" => 2
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"arrival_on" => "2027-01-04", "departure_on" => "2027-01-07"} = data
      assert data["lodging_total_cents"] == 97_500
      assert data["deposit_due_cents"] == 19_500
    end

    test "a reschedule to the current dates still counts as an applied operation", %{conn: conn} do
      open_group!(conn)

      conn =
        json_post(
          conn,
          reschedule(%{"occurred_on" => "2026-11-01", "new_arrival_on" => "2026-12-10"})
        )

      assert [
               %{
                 "status" => "applied",
                 "revision" => 2,
                 "new_arrival_on" => "2026-12-10",
                 "new_departure_on" => "2026-12-13"
               }
             ] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 2
    end

    test "the new arrival must be after the operation date", %{conn: conn} do
      open_group!(conn)

      for new_arrival_on <- ["2026-11-15", "2026-10-03", "2025-01-01"] do
        op =
          reschedule(%{
            "operation_id" => "op-move-#{new_arrival_on}",
            "new_arrival_on" => new_arrival_on,
            "occurred_on" => "2026-11-15"
          })

        [result] = json_response(json_post(conn, op), 200)["results"]
        assert result["code"] == "invalid_stay"
      end
    end

    test "an unusable new arrival is rejected with invalid_stay", %{conn: conn} do
      open_group!(conn)

      for new_arrival_on <- ["soon", 20_270_104] do
        op =
          reschedule(%{
            "operation_id" => "op-bad-arrival-#{inspect(new_arrival_on)}",
            "new_arrival_on" => new_arrival_on
          })

        [result] = json_response(json_post(conn, op), 200)["results"]
        assert result["code"] == "invalid_stay"
      end

      conn =
        json_post(
          conn,
          Map.delete(reschedule(%{"operation_id" => "op-no-arrival"}), "new_arrival_on")
        )

      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 1, "arrival_on" => "2026-12-10"} = data
    end

    test "missing or inactive groups use the group errors", %{conn: conn} do
      conn = json_post(conn, reschedule(%{"group_id" => "ghost"}))
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      open_group!(conn)
      json_post(conn, cancel())

      conn = json_post(conn, reschedule(%{"operation_id" => "op-move-cancelled"}))
      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end

    test "reschedule honours expected_revision", %{conn: conn} do
      open_group!(conn)

      op = reschedule(%{"expected_revision" => 9})
      [result] = json_response(json_post(conn, op), 200)["results"]

      assert result == %{
               "operation_id" => "op-reschedule",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      conn = json_post(conn, reschedule(%{"operation_id" => "op-move-ok"}))
      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]
    end
  end

  describe "cancel_group" do
    test "flexible groups cancelled early refund cash already paid", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, cancel())

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 10_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert %{
               "status" => "cancelled",
               "revision" => 3,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 0
             } = data

      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "fourteen calendar days before arrival is still refundable", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, cancel(%{"occurred_on" => "2026-11-26"}))

      assert [%{"status" => "applied", "refunded_cents" => 10_000, "retained_cents" => 0}] =
               json_response(conn, 200)["results"]
    end

    test "flexible groups cancelled late retain cash already paid", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, cancel(%{"occurred_on" => "2026-12-01"}))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000}] =
               json_response(conn, 200)["results"]

      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 10_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "advance purchase groups are never refundable", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "group_id" => "group-advance",
          "rate_plan" => "advance_purchase"
        })
      ])

      json_post(conn, payment(%{"group_id" => "group-advance", "amount_cents" => 50_000}))

      conn =
        json_post(conn, cancel(%{"group_id" => "group-advance", "occurred_on" => "2026-10-20"}))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 50_000}] =
               json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-advance")), 200)["data"]

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 97_500,
               "deposit_paid_cents" => 50_000,
               "outstanding_deposit_cents" => 0
             } = data
    end

    test "an unpaid deposit becomes no longer due", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, cancel())

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert %{
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "deposit_due_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             } = data

      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "missing or inactive groups use the group errors", %{conn: conn} do
      conn =
        json_post(conn, cancel(%{"operation_id" => "op-cancel-ghost", "group_id" => "ghost"}))

      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      open_group!(conn)

      conn = json_post(conn, cancel())
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = json_post(conn, cancel(%{"operation_id" => "op-cancel-again"}))
      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end

    test "after cancellation every operation is group_not_active", %{conn: conn} do
      open_group!(conn)
      json_post(conn, cancel())

      for op <- [
            payment(%{"amount_cents" => 100}),
            reschedule(),
            cancel(%{"operation_id" => "op-cancel-after"})
          ] do
        [result] = json_response(json_post(conn, op), 200)["results"]
        assert result["code"] == "group_not_active"
      end

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"status" => "cancelled", "revision" => 2} = data
    end

    test "cancel honours expected_revision", %{conn: conn} do
      open_group!(conn)

      op = cancel(%{"expected_revision" => 2})
      [result] = json_response(json_post(conn, op), 200)["results"]

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 1
             } = result

      conn = json_post(conn, cancel(%{"operation_id" => "op-cancel-ok"}))
      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["status"] == "cancelled"
    end
  end
end
