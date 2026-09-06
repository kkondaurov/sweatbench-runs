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
  Returns the decoded ledger totals from the read endpoint, optionally
  reporting expiry as of the given query parameters.
  """
  def ledger_data(conn, params \\ %{}) do
    conn
    |> Phoenix.ConnTest.dispatch(GroupStayWeb.Endpoint, :get, "/api/v1/ledger", params)
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Returns the decoded guest credit data from the read endpoint, optionally
  reporting expiry as of the given query parameters.
  """
  def guest_credit_data(conn, guest_id, params \\ %{}) do
    conn
    |> Phoenix.ConnTest.dispatch(
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/guests/#{guest_id}/credit",
      params
    )
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Records a cash payment for the example group and returns the applied result.
  """
  def pay_group(conn, group_id, amount_cents, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-pay-#{group_id}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  @doc """
  Cancels a group and returns its result.
  """
  def cancel_group(conn, group_id, occurred_on, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-cancel-#{group_id}",
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  @doc """
  Starts finance reporting and returns the result of the start operation.
  """
  def start_finance_reporting(conn, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-start-reporting",
          "type" => "start_finance_reporting",
          "occurred_on" => "2026-11-01",
          "starts_on" => "2026-11-01"
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  @doc """
  Closes the finance period and returns the result of the close operation.
  """
  def close_finance_period(conn, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-close-period",
          "type" => "close_finance_period",
          "occurred_on" => "2026-11-30",
          "period_end_on" => "2026-11-15"
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  @doc """
  Returns the decoded daily report for the given date.
  """
  def daily_report_data(conn, date) do
    conn
    |> Phoenix.ConnTest.dispatch(
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/finance/daily-report",
      %{"date" => date}
    )
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Opens a second example group for the same guest at another property and
  returns its applied result.
  """
  def open_group_at(conn, group_id, property_id, overrides \\ %{}) do
    operation =
      valid_open_operation()
      |> Map.merge(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "property_id" => property_id
      })
      |> Map.merge(overrides)

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end
end
