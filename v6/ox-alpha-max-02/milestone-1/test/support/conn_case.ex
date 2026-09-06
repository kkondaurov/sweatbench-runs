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

  setup tags do
    GroupStay.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Submits a batch of partner operations.
  """
  def submit_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  @doc """
  Submits a raw request body to the partner batch endpoint.
  """
  def submit_raw_batch(conn, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  @doc """
  Submits a batch and returns the decoded results, asserting the batch applied.
  """
  def run_batch(conn, operations) do
    assert %{"results" => results} = conn |> submit_batch(operations) |> json_response(200)
    results
  end

  @doc """
  Reads a group through the API, returning `nil` when it does not exist.
  """
  def fetch_group(conn, group_id) do
    response = get(conn, "/api/v1/groups/#{URI.encode_www_form(group_id)}")

    case response.status do
      200 ->
        json_response(response, 200)["data"]

      404 ->
        assert json_response(response, 404) == %{"error" => %{"code" => "group_not_found"}}
        nil

      other ->
        flunk("unexpected status #{other} reading group #{group_id}")
    end
  end

  @doc """
  Reads the finance totals through the API.
  """
  def fetch_ledger(conn) do
    assert %{"data" => ledger} = get(conn, "/api/v1/ledger") |> json_response(200)
    ledger
  end

  @doc """
  A valid `open_group` operation, overridable per key.
  """
  def open_operation(overrides \\ %{}) do
    Map.merge(
      %{
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
      },
      overrides
    )
  end
end
