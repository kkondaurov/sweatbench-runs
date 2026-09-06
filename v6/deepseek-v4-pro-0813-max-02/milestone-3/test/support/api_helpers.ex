defmodule GroupStay.ApiHelpers do
  @moduledoc """
  Helpers for exercising the partner API in tests.
  """

  import Plug.Conn

  @endpoint GroupStayWeb.Endpoint

  @doc """
  Sends a JSON POST to the given path, returning `{decoded_body, status}`.
  """
  def api_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, path, Jason.encode!(body))
    |> decode()
  end

  @doc """
  Sends a JSON GET to the given path, returning `{decoded_body, status}`.
  """
  def api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/json")
    |> Phoenix.ConnTest.dispatch(@endpoint, :get, path)
    |> decode()
  end

  defp decode(conn) do
    {Jason.decode!(conn.resp_body), conn.status}
  end

  @doc """
  Builds an `open_group` operation with the API example's values.
  """
  def open_group_op(overrides \\ %{}) do
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
    }
    |> Map.merge(overrides)
  end

  @doc """
  Builds a `record_cash_payment` operation.
  """
  def cash_payment_op(overrides \\ %{}) do
    %{
      "operation_id" => "op-2001",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-20",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }
    |> Map.merge(overrides)
  end

  @doc """
  Builds a `reschedule_group` operation.
  """
  def reschedule_op(overrides \\ %{}) do
    %{
      "operation_id" => "op-3001",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-81",
      "new_arrival_on" => "2026-12-20"
    }
    |> Map.merge(overrides)
  end

  @doc """
  Builds a `cancel_group` operation.
  """
  def cancel_op(overrides \\ %{}) do
    %{
      "operation_id" => "op-4001",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => "group-81"
    }
    |> Map.merge(overrides)
  end

  @doc """
  Builds an `apply_hotel_credit` operation.
  """
  def apply_hotel_credit_op(overrides \\ %{}) do
    %{
      "operation_id" => "op-5001",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-25",
      "group_id" => "group-81",
      "amount_cents" => 10_000
    }
    |> Map.merge(overrides)
  end
end
