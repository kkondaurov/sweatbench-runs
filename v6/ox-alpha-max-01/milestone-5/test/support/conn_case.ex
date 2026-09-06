defmodule GroupStayWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GroupStayWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint GroupStayWeb.Endpoint

      use GroupStayWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import GroupStayWeb.ConnCase
    end
  end

  @endpoint GroupStayWeb.Endpoint

  import Phoenix.ConnTest

  @open_operation %{
    "operation_id" => "op-1001",
    "type" => "open_group",
    "occurred_on" => "2026-10-03",
    "group_id" => "group-81",
    "guest_id" => "guest-22",
    "property_id" => "ams-canal",
    "arrival_on" => "2026-12-10",
    "departure_on" => "2026-12-13",
    "rate_plan" => "flexible",
    "rooms" => [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
    ]
  }

  # Operation identifiers are unique per helper call: since operations became
  # durably idempotent, reusing an identifier with a different payload is an
  # `operation_id_conflict`. Pass an explicit `"operation_id"` override to pin
  # or repeat an identifier deliberately.
  def open_operation(overrides \\ %{}) do
    @open_operation
    |> Map.delete("operation_id")
    |> Map.merge(overrides)
    |> Map.put_new("operation_id", "op-open-#{unique_id()}")
  end

  def payment_operation(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-payment-#{unique_id()}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def reschedule_operation(group_id, new_arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reschedule-#{unique_id()}",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival_on
      },
      overrides
    )
  end

  def cancel_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{unique_id()}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id
      },
      overrides
    )
  end

  def cancel_rooms_operation(group_id, room_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms-#{unique_id()}",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  def reduce_cash_payment_operation(payment_operation_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce-#{unique_id()}",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-01",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def charge_back_payment_operation(payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback-#{unique_id()}",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-01",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  def apply_credit_operation(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-apply-credit-#{unique_id()}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-02-10",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def transfer_deposit_operation(
        source_group_id,
        destination_group_id,
        amount_cents,
        overrides \\ %{}
      ) do
    Map.merge(
      %{
        "operation_id" => "op-transfer-#{unique_id()}",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-05",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp unique_id, do: System.unique_integer([:positive])

  def post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  # Posts a raw JSON body. The given conn is only a template: a fresh
  # connection is built so the helper is safe to reuse after responses.
  def post_raw_body(_conn, json_body) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.post("/api/v1/partner-batches", json_body)
  end

  def get_group(conn, group_id) do
    get(conn, "/api/v1/groups/#{group_id}")
  end

  def get_operation(conn, operation_id) do
    get(conn, "/api/v1/operations/#{operation_id}")
  end

  def get_payment(conn, payment_operation_id) do
    get(conn, "/api/v1/payments/#{payment_operation_id}")
  end

  def get_ledger(conn, query \\ []) do
    get(conn, "/api/v1/ledger", query)
  end

  def get_guest_credit(conn, guest_id, query \\ []) do
    get(conn, "/api/v1/guests/#{guest_id}/credit", query)
  end

  setup tags do
    GroupStay.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
