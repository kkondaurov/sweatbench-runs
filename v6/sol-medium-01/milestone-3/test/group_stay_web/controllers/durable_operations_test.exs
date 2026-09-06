defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Groups.PartnerOperation
  alias GroupStay.Repo

  test "an equivalent retry returns the original result without applying again", %{conn: conn} do
    open = open_operation("open-1", "group-1")

    assert %{"results" => [%{"revision" => 1}]} = submit(conn, [open])

    payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 1_000
    }

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-1",
                 "status" => "applied",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 5_000,
                 "revision" => 2
               }
             ]
           } = submit(conn, [payment])

    assert %{"results" => [%{"revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "move-1",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group-1",
                 "new_arrival_on" => "2027-01-10"
               }
             ])

    # Reconstructing the maps also verifies that object key insertion order is irrelevant.
    equivalent_payment =
      Enum.into(
        [
          {"amount_cents", 1_000},
          {"group_id", "group-1"},
          {"occurred_on", "2026-10-04"},
          {"type", "record_cash_payment"},
          {"operation_id", "payment-1"}
        ],
        %{}
      )

    assert %{"results" => [%{"revision" => 2, "outstanding_deposit_cents" => 5_000}]} =
             submit(conn, [equivalent_payment])

    assert %{
             "data" => %{
               "revision" => 3,
               "cash_paid_cents" => 1_000,
               "outstanding_deposit_cents" => 5_000
             }
           } = get_json(conn, "/api/v1/groups/group-1")
  end

  test "rejected results are remembered even after domain state changes", %{conn: conn} do
    missing_payment = %{
      "operation_id" => "missing-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "later-group",
      "amount_cents" => 1_000
    }

    expected = %{
      "operation_id" => "missing-payment",
      "status" => "rejected",
      "code" => "group_not_found",
      "group_id" => "later-group"
    }

    assert %{"results" => [^expected]} = submit(conn, [missing_payment])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [open_operation("open-later", "later-group")])

    assert %{"results" => [^expected]} = submit(conn, [missing_payment])

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get_json(conn, "/api/v1/groups/later-group")
  end

  test "a stale-revision retry preserves the originally observed revision", %{conn: conn} do
    submit(conn, [open_operation("open-stale", "stale-group")])

    stale = %{
      "operation_id" => "stale-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "stale-group",
      "amount_cents" => 500,
      "expected_revision" => 0
    }

    expected = %{
      "operation_id" => "stale-payment",
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => "stale-group",
      "expected_revision" => 0,
      "actual_revision" => 1
    }

    assert %{"results" => [^expected]} = submit(conn, [stale])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "later-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "stale-group",
                 "amount_cents" => 500
               }
             ])

    assert %{"results" => [^expected]} = submit(conn, [stale])

    corrected = %{stale | "expected_revision" => 2}

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [corrected])
  end

  test "reusing an operation id with a changed payload conflicts and keeps the original", %{
    conn: conn
  } do
    original = open_operation("shared-id", "original-group")

    assert %{"results" => [%{"status" => "applied", "group_id" => "original-group"}]} =
             submit(conn, [original])

    changed = put_in(original["group_id"], "different-group")

    assert %{
             "results" => [
               %{
                 "operation_id" => "shared-id",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = submit(conn, [changed])

    assert %{"error" => %{"code" => "group_not_found"}} =
             get_json(conn, "/api/v1/groups/different-group", 404)

    assert %{"data" => %{"operation_id" => "shared-id", "status" => "applied"}} =
             get_json(conn, "/api/v1/operations/shared-id")
  end

  test "operation reads expose only the result and missing operations return 404", %{conn: conn} do
    submitted =
      open_operation("audited", "audit-group")
      |> Map.put("gateway_metadata", %{"trace" => "trace-7", "flags" => [1, 2, 3]})

    assert %{"results" => [result]} = submit(conn, [submitted])
    assert %{"data" => ^result} = get_json(conn, "/api/v1/operations/audited")
    refute Map.has_key?(result, "submission")
    refute Map.has_key?(result, "operation_type")

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get_json(conn, "/api/v1/operations/unknown", 404)

    record = Repo.get_by!(PartnerOperation, operation_id: "audited")
    assert record.operation_type == "open_group"
    assert record.submission == submitted
    assert record.result == result
  end

  test "durable records retain first-commit order for applied and rejected operations", %{
    conn: conn
  } do
    invalid = %{"operation_id" => "invalid-1", "type" => "unknown", "nested" => [%{"b" => 2}]}
    missing_type = %{"operation_id" => "invalid-2", "submitted" => true}

    assert %{"results" => [%{"status" => "rejected"}, %{"status" => "rejected"}]} =
             submit(conn, [invalid, missing_type])

    records =
      Repo.all(
        from operation in PartnerOperation,
          where: operation.operation_id in ["invalid-1", "invalid-2"],
          order_by: [asc: operation.id]
      )

    assert Enum.map(records, & &1.operation_id) == ["invalid-1", "invalid-2"]
    assert Enum.map(records, & &1.submission) == [invalid, missing_type]
    assert Enum.map(records, & &1.operation_type) == ["unknown", nil]
  end

  test "duplicate operations in one batch have at-most-once effects", %{conn: conn} do
    operation = open_operation("same-in-batch", "one-group")

    assert %{"results" => [first, second]} = submit(conn, [operation, operation])
    assert first == second
    assert first["status"] == "applied"
    assert Repo.aggregate(PartnerOperation, :count, :id) == 1
    assert %{"data" => %{"revision" => 1}} = get_json(conn, "/api/v1/groups/one-group")
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_json(conn, path, status \\ 200) do
    conn
    |> get(path)
    |> json_response(status)
  end

  defp open_operation(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    }
  end
end
