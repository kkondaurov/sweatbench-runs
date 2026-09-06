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

  @doc """
  Submits the given operations to the partner batch endpoint and returns the
  decoded 200 response body.
  """
  def submit_batch(conn, operations) do
    conn
    |> Phoenix.ConnTest.dispatch(GroupStayWeb.Endpoint, :post, "/api/v1/partner-batches", %{
      "operations" => operations
    })
    |> Phoenix.ConnTest.json_response(200)
  end

  @doc """
  A syntactically valid open_group operation matching the API document example.
  """
  def valid_open_operation do
    %{
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
  end

  @doc """
  Opens the example group (with optional field overrides) and returns its
  applied result.
  """
  def open_group_fixture(conn, overrides \\ %{}) do
    operation = Map.merge(valid_open_operation(), overrides)
    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  @doc """
  Returns the decoded group data from the read endpoint.
  """
  def group_data(conn, group_id) do
    conn
    |> Phoenix.ConnTest.dispatch(GroupStayWeb.Endpoint, :get, "/api/v1/groups/#{group_id}")
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Returns the decoded ledger totals from the read endpoint.
  """
  def ledger_data(conn) do
    conn
    |> Phoenix.ConnTest.dispatch(GroupStayWeb.Endpoint, :get, "/api/v1/ledger")
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end
end
