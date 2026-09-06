defmodule GroupStayWeb.PartnerAPI do
  @moduledoc """
  Helpers for exercising the partner API through the batch endpoint.
  """

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GroupStayWeb.Endpoint

  @doc """
  An `open_group` operation matching the API document example.
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

  def pay_operation(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def reschedule_operation(group_id, new_arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reschedule",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival_on
      },
      overrides
    )
  end

  def cancel_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id
      },
      overrides
    )
  end

  def credit_operation(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def cancel_rooms_operation(group_id, room_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  def reduce_cash_operation(payment_operation_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def charge_back_operation(payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-charge-back",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  def transfer_operation(source_group_id, destination_group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def start_reporting_operation(starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  def close_period_operation(period_end_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-close-period",
        "type" => "close_finance_period",
        "period_end_on" => period_end_on
      },
      overrides
    )
  end

  def post_operations(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  def post_raw_body(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  def fetch_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{URI.encode(group_id)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def fetch_ledger(on \\ nil) do
    query = if on, do: "?on=#{on}", else: ""

    build_conn()
    |> get("/api/v1/ledger#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def fetch_credit(guest_id, on \\ nil) do
    query = if on, do: "?on=#{on}", else: ""

    build_conn()
    |> get("/api/v1/guests/#{URI.encode(guest_id)}/credit#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def open_default_group(group_id \\ "group-81") do
    open_operation(%{"group_id" => group_id})
    |> List.wrap()
    |> post_operations()

    group_id
  end

  def fetch_payment(payment_operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{URI.encode(payment_operation_id)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def fetch_daily_report(date) do
    query = if date, do: "?date=#{date}", else: ""

    build_conn()
    |> get("/api/v1/finance/daily-report#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def fetch_daily_report_error(date) do
    query = if date, do: "?date=#{date}", else: ""

    build_conn()
    |> get("/api/v1/finance/daily-report#{query}")
    |> json_response(:unprocessable_entity)
    |> Map.fetch!("error")
    |> Map.fetch!("code")
  end
end
