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

  import GroupStay.OperationFixtures

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
  Submits operations written as raw JSON, so a test can choose the order of object keys.
  """
  def submit_raw(operations) when is_list(operations) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(
        GroupStayWeb.Endpoint,
        :post,
        "/api/v1/partner-batches",
        ~s({"operations":[) <> Enum.join(operations, ",") <> ~s(]})
      )

    Phoenix.ConnTest.json_response(conn, 200)["results"]
  end

  @doc """
  Issues a GET against the API, returning the status and the decoded body.
  """
  def get_json(path, params \\ %{}) do
    conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        GroupStayWeb.Endpoint,
        :get,
        path,
        params
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @doc """
  Reads a group through the API, returning the decoded body and the status.
  """
  def read_group(group_id),
    do: get_json("/api/v1/groups/" <> encode(group_id))

  @doc """
  Reads the result remembered for an operation through the API.
  """
  def read_operation(operation_id),
    do: get_json("/api/v1/operations/" <> encode(operation_id))

  @doc """
  Reads the finance totals through the API.
  """
  def read_ledger(params \\ %{}) do
    {200, body} = get_json("/api/v1/ledger", params)
    body["data"]
  end

  @doc """
  Reads a guest's hotel credit through the API.
  """
  def read_credit(guest_id, params \\ %{}) do
    {200, body} = get_json("/api/v1/guests/" <> encode(guest_id) <> "/credit", params)
    body["data"]
  end

  # Issues hotel credit to a guest the only way the product allows: a flexible group funded with
  # cash and cancelled while it is still refundable, settled as hotel credit.
  def issue_credit(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    cash_cents = Keyword.fetch!(opts, :cash_cents)
    operation_id = Keyword.fetch!(opts, :operation_id)
    guest_id = Keyword.get(opts, :guest_id, "guest-22")
    cancelled_on = Keyword.get(opts, :cancelled_on, "2026-11-26")

    submit([
      # One night at five times the cash makes the 20% deposit exactly the cash paid.
      open_group(%{
        "operation_id" => "op-open-" <> group_id,
        "group_id" => group_id,
        "guest_id" => guest_id,
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-11",
        "rooms" => [room("room-a", cash_cents * 5)]
      }),
      record_cash_payment(%{
        "operation_id" => "op-pay-" <> group_id,
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      cancel_group(%{
        "operation_id" => operation_id,
        "group_id" => group_id,
        "occurred_on" => cancelled_on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp encode(identifier), do: URI.encode(identifier, &URI.char_unreserved?/1)
end
