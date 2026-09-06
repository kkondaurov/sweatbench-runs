defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Deposits.PartnerOperation
  alias GroupStay.Repo

  defp open_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "an equivalent retry returns the original result without changing current state", %{
    conn: conn
  } do
    open = open_operation("open", "group")
    pay = payment("pay", "group", 500, %{"expected_revision" => 1})

    assert [
             %{"status" => "applied", "revision" => 1},
             %{
               "operation_id" => "pay",
               "status" => "applied",
               "group_id" => "group",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 1_500,
               "revision" => 2
             }
           ] = submit(conn, [open, pay])

    assert [%{"status" => "applied", "revision" => 3}] =
             submit(conn, [payment("later", "group", 250, %{"expected_revision" => 2})])

    # Rebuilding the nested objects also demonstrates that map key insertion order is irrelevant.
    equivalent_pay =
      Enum.into(
        [
          {"amount_cents", 500},
          {"group_id", "group"},
          {"occurred_on", "2027-01-02"},
          {"type", "record_cash_payment"},
          {"expected_revision", 1},
          {"operation_id", "pay"}
        ],
        %{}
      )

    assert [
             %{
               "operation_id" => "pay",
               "status" => "applied",
               "group_id" => "group",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 1_500,
               "revision" => 2
             }
           ] = submit(conn, [equivalent_pay])

    assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 750}} =
             get(conn, "/api/v1/groups/group") |> json_response(200)

    assert %{"data" => %{"operation_id" => "pay", "revision" => 2}} =
             get(conn, "/api/v1/operations/pay") |> json_response(200)
  end

  test "handled rejections are remembered even when domain state later makes the payload valid",
       %{
         conn: conn
       } do
    pay = payment("pay-missing", "future-group", 100)

    assert [
             %{
               "operation_id" => "pay-missing",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "future-group"
             }
           ] = submit(conn, [pay])

    assert [%{"status" => "applied"}] =
             submit(conn, [open_operation("open-future", "future-group")])

    assert [%{"code" => "group_not_found", "group_id" => "future-group"}] =
             submit(conn, [pay])

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get(conn, "/api/v1/groups/future-group") |> json_response(200)
  end

  test "a changed payload conflicts and cannot replace the original result", %{conn: conn} do
    submit(conn, [open_operation("open", "group")])

    stale = payment("stale-pay", "group", -1, %{"expected_revision" => 9})

    assert [%{"code" => "stale_revision", "expected_revision" => 9, "actual_revision" => 1}] =
             submit(conn, [stale])

    corrected = payment("stale-pay", "group", 100, %{"expected_revision" => 1})

    assert [
             %{
               "operation_id" => "stale-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ] = submit(conn, [corrected])

    assert %{
             "data" => %{
               "code" => "stale_revision",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
           } = get(conn, "/api/v1/operations/stale-pay") |> json_response(200)

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get(conn, "/api/v1/groups/group") |> json_response(200)
  end

  test "audit records retain complete submissions and first-commit order", %{conn: conn} do
    rejected_payload = %{
      "operation_id" => "unknown",
      "type" => "future_operation",
      "extra" => %{"ordered_values" => [3, 2, 1], "nullable" => nil}
    }

    malformed_payload = %{"operation_id" => "missing-type", "arbitrary" => true}
    open_payload = open_operation("open", "group")

    assert [
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"status" => "applied"}
           ] = submit(conn, [rejected_payload, malformed_payload, open_payload])

    records =
      Repo.all(
        from operation in PartnerOperation,
          order_by: [asc: operation.id],
          select: {operation.operation_id, operation.operation_type, operation.payload}
      )

    assert [
             {"unknown", "future_operation", ^rejected_payload},
             {"missing-type", nil, ^malformed_payload},
             {"open", "open_group", ^open_payload}
           ] = records

    # Exact retries and conflicts do not create new audit entries.
    submit(conn, [rejected_payload, Map.put(rejected_payload, "extra", "changed")])
    assert Repo.aggregate(PartnerOperation, :count) == 3
  end

  test "the operation read endpoint returns the normal not-found shape", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(conn, "/api/v1/operations/absent") |> json_response(404)
  end
end
