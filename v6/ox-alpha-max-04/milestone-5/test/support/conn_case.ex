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

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint GroupStayWeb.Endpoint

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

  @doc """
  Posts a batch of operations to the partner batch endpoint as JSON.
  """
  def post_operations(conn, operations) do
    conn
    |> Phoenix.ConnTest.ensure_recycled()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  @doc """
  Posts a raw JSON body to the partner batch endpoint.
  """
  def post_batch_body(conn, body) do
    conn
    |> Phoenix.ConnTest.ensure_recycled()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  @doc """
  Builds an `open_group` operation, overridable field by field.
  """
  def open_group_operation(overrides \\ %{}) do
    Map.merge(
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  @doc """
  Fetches the current group resource through the read endpoint, failing the
  test when the group is missing.
  """
  def fetch_group!(conn, group_id) do
    response = get(conn, "/api/v1/groups/#{group_id}")
    assert %{"data" => group} = json_response(response, 200)
    group
  end

  setup tags do
    GroupStay.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
