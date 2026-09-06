defmodule GroupStay.BatchHelpers do
  @moduledoc """
  Builders for partner operations and conveniences for submitting batches in
  tests.
  """

  import Phoenix.ConnTest
  import ExUnit.Assertions

  use GroupStayWeb, :verified_routes

  @endpoint GroupStayWeb.Endpoint

  @doc """
  A valid `open_group` operation matching the API document example. Pass
  overrides to exercise validation rules.
  """
  def open_group_op(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  def record_cash_payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10_000
      },
      overrides
    )
  end

  def reschedule_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-3001",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  def cancel_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  def apply_hotel_credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-5001",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-10",
        "group_id" => "group-82",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  @doc """
  POSTs a batch and returns the decoded `results` list. Asserts a 200 status.
  """
  def post_batch!(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  @doc """
  Applies a batch of operations and asserts every one was applied.
  """
  def apply_batch!(conn, operations) do
    results = post_batch!(conn, operations)

    for result <- results do
      assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    end

    results
  end

  @doc """
  Opens the default example group and returns the applied result.
  """
  def open_group!(conn, overrides \\ %{}) do
    [result] = apply_batch!(conn, [open_group_op(overrides)])
    result
  end

  @doc """
  Reads a group through the API and asserts a 200 status.
  """
  def get_group!(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Reads the ledger through the API and asserts a 200 status. An optional
  `on` date sets the as-of date for credit expiry.
  """
  def get_ledger!(conn, on \\ nil) do
    conn
    |> get(if(on, do: ~p"/api/v1/ledger?on=#{on}", else: ~p"/api/v1/ledger"))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Reads a guest's credit through the API and asserts a 200 status. An
  optional `on` date sets the as-of date for credit expiry.
  """
  def get_credit!(conn, guest_id, on \\ nil) do
    path =
      if on do
        ~p"/api/v1/guests/#{guest_id}/credit?on=#{on}"
      else
        ~p"/api/v1/guests/#{guest_id}/credit"
      end

    conn
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  Builds a fresh connection for an additional request in the same test.
  """
  def fresh_conn do
    Phoenix.ConnTest.build_conn()
  end
end
