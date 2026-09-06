defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.ConnTest

  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Repo

  test "replays an equivalent operation verbatim without applying it a second time", %{conn: conn} do
    open = open_group()
    payment = cash_payment("pay-1", "group-1", 5_000)

    assert %{
             "results" => [
               %{"operation_id" => "open-1", "status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           } = post_operations(conn, [open, payment])

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             post_operations(build_conn(), [cash_payment("pay-2", "group-1", 1_000)])

    equivalent_payment = payment |> Map.to_list() |> Enum.reverse() |> Map.new()

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           } = post_operations(build_conn(), [equivalent_payment])

    assert %{"data" => %{"deposit_paid_cents" => 6_000, "revision" => 3}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    assert %{
             "data" => %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }
           } = get(build_conn(), "/api/v1/operations/pay-1") |> json_response(200)
  end

  test "remembers rejections and rejects reused identifiers with changed payloads", %{conn: conn} do
    missing_payment = cash_payment("pay-before-open", "group-1", 500)

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-before-open",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           } = post_operations(conn, [missing_payment])

    assert %{"results" => [%{"operation_id" => "open-1", "status" => "applied"}]} =
             post_operations(build_conn(), [open_group()])

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-before-open",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           } = post_operations(build_conn(), [missing_payment])

    corrected_payment = Map.put(missing_payment, "expected_revision", 1)

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-before-open",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = post_operations(build_conn(), [corrected_payment])

    assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
  end

  test "replays stale revision details observed by the original attempt", %{conn: conn} do
    stale_payment =
      cash_payment("stale-payment", "group-1", 1)
      |> Map.put("expected_revision", 0)

    assert %{
             "results" => [
               %{"operation_id" => "open-1", "status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } = post_operations(conn, [open_group(), stale_payment])

    assert %{"results" => [%{"operation_id" => "pay-2", "status" => "applied", "revision" => 2}]} =
             post_operations(build_conn(), [cash_payment("pay-2", "group-1", 1_000)])

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } = post_operations(build_conn(), [stale_payment])

    corrected_stale_payment = Map.put(stale_payment, "expected_revision", 2)

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = post_operations(build_conn(), [corrected_stale_payment])
  end

  test "records rejected submissions for audit in their first-commit order", %{conn: conn} do
    rejected = %{
      "operation_id" => "unknown-1",
      "type" => "future_operation",
      "occurred_on" => "2027-01-01",
      "metadata" => %{"source" => "gateway", "attempt" => 1}
    }

    assert %{
             "results" => [
               %{
                 "operation_id" => "unknown-1",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "open-1", "status" => "applied"}
             ]
           } = post_operations(conn, [rejected, open_group()])

    records = Repo.all(from(record in Operation, order_by: [asc: record.id]))

    assert Enum.map(records, & &1.operation_id) == ["unknown-1", "open-1"]

    assert [%{operation_type: "future_operation", payload: payload, result: result} | _] = records
    assert payload == rejected

    assert result == %{
             "operation_id" => "unknown-1",
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    assert %{
             "data" => %{
               "operation_id" => "unknown-1",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
           } = get(build_conn(), "/api/v1/operations/unknown-1") |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(build_conn(), "/api/v1/operations/missing-operation") |> json_response(404)
  end

  test "treats array changes as a conflicting payload", %{conn: conn} do
    open = open_group()

    assert %{"results" => [%{"operation_id" => "open-1", "status" => "applied"}]} =
             post_operations(conn, [open])

    changed_room_order = %{open | "rooms" => Enum.reverse(open["rooms"])}

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = post_operations(build_conn(), [changed_room_order])

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
  end

  defp open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-1",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
