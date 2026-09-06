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

  setup tags do
    GroupStay.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @base_open_operation %{
    "operation_id" => "op-open",
    "type" => "open_group",
    "occurred_on" => "2026-10-03",
    "group_id" => "group-81",
    "guest_id" => "guest-22",
    "property_id" => "ams-canal",
    "arrival_on" => "2026-12-10",
    "departure_on" => "2026-12-13",
    "rate_plan" => "flexible",
    "rooms" => [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
    ]
  }

  @doc """
  The example `open_group` operation from the API document, with overrides merged in.
  """
  def open_operation(overrides \\ %{}) do
    Map.merge(@base_open_operation, Map.new(overrides))
  end

  @doc """
  Posts an operations array to the partner batch endpoint as JSON.
  """
  def submit_batch(conn, operations) do
    body = Jason.encode!(%{"operations" => operations})

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(GroupStayWeb.Endpoint, :post, "/api/v1/partner-batches", body)
  end

  @doc """
  Posts raw JSON to the partner batch endpoint.
  """
  def submit_raw(conn, json) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(GroupStayWeb.Endpoint, :post, "/api/v1/partner-batches", json)
  end

  @doc """
  Fetches a group by identifier.
  """
  def get_group(conn, group_id) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/groups/" <> group_id,
      nil
    )
  end

  @doc """
  Fetches the finance totals.
  """
  def get_ledger(conn, query_params \\ []) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/ledger" <> query_string(query_params),
      nil
    )
  end

  @doc """
  Fetches a guest's available hotel credit.
  """
  def get_guest_credit(conn, guest_id, query_params \\ []) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/guests/" <> guest_id <> "/credit" <> query_string(query_params),
      nil
    )
  end

  defp query_string([]), do: ""

  defp query_string(params) do
    "?" <> Plug.Conn.Query.encode(Map.new(params))
  end
end
