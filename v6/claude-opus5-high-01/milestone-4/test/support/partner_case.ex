defmodule GroupStayWeb.PartnerCase do
  @moduledoc """
  Helpers for driving the partner API over real JSON requests.

  Bodies are encoded to JSON so tests exercise the same value types a partner
  gateway sends (integers stay integers, missing keys stay missing).
  """

  import Phoenix.ConnTest

  @endpoint GroupStayWeb.Endpoint

  @doc "Submits a batch and returns the decoded response body."
  def submit(conn, operations) when is_list(operations) do
    conn |> post_batch(%{"operations" => operations}) |> json_response(200)
  end

  @doc "Submits a batch of one operation and returns its single result."
  def submit_one(conn, operation) do
    %{"results" => [result]} = submit(conn, [operation])
    result
  end

  @doc "Submits an arbitrary request body to the batch endpoint."
  def post_batch(conn, body) do
    post_raw_batch(conn, Jason.encode!(body))
  end

  @doc """
  Submits raw JSON to the batch endpoint, byte for byte.

  Use this when the test needs to control the order of the keys the gateway sends.
  """
  def post_raw_batch(conn, json) when is_binary(json) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", json)
  end

  @doc "Reads the stored result of a remembered operation over the API."
  def read_operation(conn, operation_id) do
    conn |> get("/api/v1/operations/#{operation_id}") |> json_response(200) |> Map.fetch!("data")
  end

  @doc "Reads a group over the API."
  def read_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  @doc "Reads the finance totals over the API, optionally as of a given date."
  def read_ledger(conn, query \\ []) do
    conn
    |> get("/api/v1/ledger?" <> URI.encode_query(query))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc "Reads the reconciliation statement of one recorded payment over the API."
  def read_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc "Reads a guest's hotel credit over the API, optionally as of a given date."
  def read_credit(conn, guest_id, query \\ []) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?" <> URI.encode_query(query))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc """
  An `open_group` operation with defaults for every field.

  The default stay is three nights of two flexible rooms, so the default deposit
  due is 19_500 cents.
  """
  def open_group_op(overrides \\ %{}) do
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
      stringify(overrides)
    )
  end

  def payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10_000
      },
      stringify(overrides)
    )
  end

  def credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10_000
      },
      stringify(overrides)
    )
  end

  def reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-17"
      },
      stringify(overrides)
    )
  end

  def cancel_rooms_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      stringify(overrides)
    )
  end

  def reduce_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1000
      },
      stringify(overrides)
    )
  end

  def charge_back_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-charge-back",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "op-pay"
      },
      stringify(overrides)
    )
  end

  def cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81"
      },
      stringify(overrides)
    )
  end

  defp stringify(overrides) do
    Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
  end
end
