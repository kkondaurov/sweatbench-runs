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
      import GroupStay.OperationFixtures
    end
  end

  setup tags do
    GroupStay.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Submits a partner batch and returns the raw connection.

  The body is sent as JSON so operations keep their JSON types.
  """
  def submit_batch(body) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(
      GroupStayWeb.Endpoint,
      :post,
      "/api/v1/partner-batches",
      Jason.encode!(body)
    )
  end

  @doc """
  Submits operations as a valid batch and returns the list of results.
  """
  def submit(operations) when is_list(operations) do
    Phoenix.ConnTest.json_response(submit_batch(%{"operations" => operations}), 200)["results"]
  end

  @doc """
  Submits a single operation and returns its result.
  """
  def submit_one(operation), do: [operation] |> submit() |> hd()

  @doc """
  Reads a group through the API, returning the decoded body and the status.
  """
  def read_group(group_id) do
    conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        GroupStayWeb.Endpoint,
        :get,
        "/api/v1/groups/" <> URI.encode(group_id, &URI.char_unreserved?/1),
        nil
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Reads the finance totals through the API.
  """
  def read_ledger do
    conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        GroupStayWeb.Endpoint,
        :get,
        "/api/v1/ledger",
        nil
      )

    Phoenix.ConnTest.json_response(conn, 200)["data"]
  end
end
