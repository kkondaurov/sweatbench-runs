defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Bookings
  alias GroupStay.Bookings.PartnerOperation
  alias GroupStay.Repo

  test "an applied retry returns its original result without consulting current state", %{
    conn: conn
  } do
    open = open_operation("durable-group", "open-durable")

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open, open]})
    assert %{"results" => [original_result, repeated_result]} = json_response(conn, 200)
    assert repeated_result == original_result

    payment = operation("pay-after-open", "record_cash_payment", "durable-group", 500)
    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [payment]})
    assert %{"results" => [%{"revision" => 2}]} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [open]})
    assert json_response(conn, 200) == %{"results" => [original_result]}

    conn = get(build_conn(), ~p"/api/v1/groups/durable-group")

    assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 500, "rooms" => [_]}} =
             json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/operations/open-durable")
    assert json_response(conn, 200) == %{"data" => original_result}
  end

  test "a rejected retry remains rejected after domain state changes", %{conn: conn} do
    payment = operation("missing-payment", "record_cash_payment", "later-group", 500)

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [payment]})

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "missing-payment",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           }

    open = open_operation("later-group", "open-later")
    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [open]})
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [payment]})
    assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/operations/missing-payment")

    assert %{"data" => %{"status" => "rejected", "code" => "group_not_found"}} =
             json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/later-group")
    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = json_response(conn, 200)
  end

  test "stale details are replayed exactly and a corrected payload conflicts", %{conn: conn} do
    open = open_operation("revision-group", "open-revision")
    payment = operation("advance-revision", "record_cash_payment", "revision-group", 100)

    stale = %{
      "operation_id" => "stale-move",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "revision-group",
      "new_arrival_on" => "2027-01-10",
      "expected_revision" => 1
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [open, payment, stale]
      })

    assert %{"results" => [_, _, original_stale]} = json_response(conn, 200)
    assert original_stale["actual_revision"] == 2

    second_payment = operation("advance-again", "record_cash_payment", "revision-group", 100)
    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [second_payment]})
    assert %{"results" => [%{"revision" => 3}]} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [stale]})
    assert json_response(conn, 200) == %{"results" => [original_stale]}

    corrected = Map.put(stale, "expected_revision", 3)
    after_conflict = operation("after-conflict", "record_cash_payment", "revision-group", 100)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [corrected, after_conflict]
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale-move",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               },
               %{"operation_id" => "after-conflict", "status" => "applied", "revision" => 4}
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/revision-group")

    assert %{"data" => %{"revision" => 4, "arrival_on" => "2026-12-10"}} =
             json_response(conn, 200)
  end

  test "payload object order is irrelevant while array order and values are significant", %{
    conn: conn
  } do
    first_body =
      ~s({"operations":[{"operation_id":"json-order","type":"open_group","occurred_on":"2026-10-03","group_id":"json-order-group","guest_id":"guest","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-11","rate_plan":"flexible","rooms":[{"room_id":"one","nightly_rate_cents":1000},{"room_id":"two","nightly_rate_cents":2000}]}]})

    reordered_body =
      ~s({"operations":[{"rooms":[{"nightly_rate_cents":1000,"room_id":"one"},{"nightly_rate_cents":2000,"room_id":"two"}],"rate_plan":"flexible","departure_on":"2026-12-11","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest","group_id":"json-order-group","occurred_on":"2026-10-03","type":"open_group","operation_id":"json-order"}]})

    conn = json_post(conn, first_body)
    assert %{"results" => [original_result]} = json_response(conn, 200)

    conn = json_post(build_conn(), reordered_body)
    assert json_response(conn, 200) == %{"results" => [original_result]}

    reversed_rooms =
      open_operation("json-order-group", "json-order")
      |> Map.put("rooms", [
        %{"room_id" => "two", "nightly_rate_cents" => 2_000},
        %{"room_id" => "one", "nightly_rate_cents" => 1_000}
      ])
      |> Map.put("guest_id", "guest")
      |> Map.put("departure_on", "2026-12-11")

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [reversed_rooms]})
    assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)

    changed_value =
      first_body
      |> Jason.decode!()
      |> get_in(["operations", Access.at(0)])
      |> put_in(["rooms", Access.at(0), "nightly_rate_cents"], 1_001)

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [changed_value]})
    assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)
  end

  test "audit records retain submissions, results, types, and first-commit order", %{conn: conn} do
    invalid = %{
      "operation_id" => "audit-invalid",
      "type" => "summon_gremlin",
      "extra" => %{"b" => 2}
    }

    open = open_operation("audit-group", "audit-open")

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [invalid, open, invalid]})

    assert %{"results" => [invalid_result, open_result, repeated_invalid_result]} =
             json_response(conn, 200)

    assert repeated_invalid_result == invalid_result

    records = Repo.all(from operation in PartnerOperation, order_by: operation.commit_order)

    assert Enum.map(records, & &1.operation_id) == ["audit-invalid", "audit-open"]
    assert Enum.map(records, & &1.operation_type) == ["summon_gremlin", "open_group"]
    assert Enum.at(records, 0).submission === invalid
    assert Enum.at(records, 0).result === invalid_result
    assert Enum.at(records, 1).submission === open
    assert Enum.at(records, 1).result === open_result
  end

  test "the operation endpoint returns the usual not-found shape", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/operations/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "an unexpected failure rolls back the current operation and aborts the batch" do
    before_failure = open_operation("before-failure", "before-failure")

    failing =
      open_operation("rolled-back", "failing-operation")
      |> Map.put("unencodable_audit_value", self())

    after_failure = open_operation("after-failure", "after-failure")

    assert_raise Ecto.ChangeError, fn ->
      Bookings.apply_batch([before_failure, failing, after_failure])
    end

    assert {:ok, _group} = Bookings.get_group("before-failure")
    assert {:ok, _result} = Bookings.get_operation("before-failure")
    assert :error = Bookings.get_group("rolled-back")
    assert :error = Bookings.get_operation("failing-operation")
    assert :error = Bookings.get_group("after-failure")
    assert :error = Bookings.get_operation("after-failure")
  end

  test "retrying an accounting operation does not repeat cash or credit effects", %{conn: conn} do
    open = open_operation("credit-source", "open-credit-source")
    payment = operation("pay-credit-source", "record_cash_payment", "credit-source", 1_000)

    cancellation = %{
      "operation_id" => "convert-credit-source",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "credit-source",
      "refund_method" => "hotel_credit"
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [open, payment, cancellation, cancellation]
      })

    assert %{"results" => [_, _, first_cancellation, repeated_cancellation]} =
             json_response(conn, 200)

    assert repeated_cancellation == first_cancellation
    assert first_cancellation["credit_issued_cents"] == 1_100
    assert first_cancellation["revision"] == 3

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2026-10-03")

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 1_000,
               "credit_liability_cents" => 1_100
             }
           } = json_response(conn, 200)

    assert Repo.aggregate(PartnerOperation, :count) == 3
  end

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", body)
  end

  defp open_operation(group_id, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 10_000}]
    }
  end

  defp operation(operation_id, type, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => type,
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end
end
