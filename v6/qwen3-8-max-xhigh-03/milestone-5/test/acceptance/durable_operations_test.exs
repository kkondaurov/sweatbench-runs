defmodule GroupStayWeb.DurableOperationsAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of durable operations: the gateway submits a batch,
  loses the response, and retries. Replays return the stored results without
  re-applying anything, a conflicting reuse of an identifier is rejected, and
  the durable records keep an ordered audit trail of what was submitted.
  """

  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group_data(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp stored(conn, operation_id) do
    conn |> get("/api/v1/operations/#{operation_id}") |> json_response(200) |> Map.fetch!("data")
  end

  test "retries replay stored results and the audit trail preserves submissions", %{conn: conn} do
    batch = [
      %{
        "operation_id" => "op-3001",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      %{
        "operation_id" => "op-3002",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 2_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "op-3003",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 99_999
      }
    ]

    # The first submission applies, and the oversized payment is rejected.
    results = submit(conn, batch)
    assert Enum.map(results, & &1["status"]) == ~w(applied applied rejected)
    assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"

    # The gateway loses the response and retries the whole batch: every
    # result comes back verbatim and nothing is applied twice.
    assert submit(conn, batch) == results

    group = group_data(conn, "group-81")
    assert group["deposit_paid_cents"] == 2_000
    assert group["revision"] == 2

    # Reusing an identifier with a corrected payload is a conflict, and the
    # original record survives it.
    corrected = List.replace_at(batch, 2, Map.put(Enum.at(batch, 2), "amount_cents", 1_000))
    results = submit(conn, corrected)
    assert Enum.at(results, 2)["code"] == "operation_id_conflict"

    assert stored(conn, "op-3003")["code"] == "payment_exceeds_outstanding"
    assert stored(conn, "op-3002")["revision"] == 2

    # The durable records audit what was submitted, in first-commit order.
    records = Repo.all(from r in Record, order_by: [asc: r.id])
    assert Enum.map(records, & &1.operation_id) == ~w(op-3001 op-3002 op-3003)
    assert Enum.map(records, & &1.type) == ~w(open_group record_cash_payment record_cash_payment)

    assert Enum.map(records, fn record -> Jason.decode!(record.payload) end) == batch

    # Unknown identifiers are not exposed as anything else.
    conn = get(conn, "/api/v1/operations/op-9999")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end
end
