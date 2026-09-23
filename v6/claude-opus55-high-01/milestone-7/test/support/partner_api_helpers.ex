defmodule GroupStayWeb.PartnerApiHelpers do
  @moduledoc "Helpers for exercising the partner API in tests."

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GroupStayWeb.Endpoint

  @doc """
  A fresh operation identifier. `operation_id` is idempotent, so operation helpers use a new one
  unless a test overrides it.
  """
  def unique_operation_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "An `open_group` operation based on the API document's example."
  def open_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-open"),
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

  def payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  def reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-move"),
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  def cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  def apply_credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  def cancel_rooms_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-cancel-rooms"),
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  def reduce_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-reduce"),
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-07",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  def charge_back_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-chargeback"),
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-08"
      },
      overrides
    )
  end

  def start_reporting_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-start-reporting"),
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-05",
        "starts_on" => "2026-10-05"
      },
      overrides
    )
  end

  def close_period_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-close-period"),
        "type" => "close_finance_period",
        "occurred_on" => "2026-10-10",
        "period_end_on" => "2026-10-09"
      },
      overrides
    )
  end

  @doc "Posts a batch and returns the decoded results, asserting a 200 response."
  def submit(operations) do
    build_conn()
    |> post_json("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  @doc "Posts a single operation and returns its result."
  def submit_one(operation) do
    [result] = submit([operation])
    result
  end

  def post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  def get_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{URI.encode(group_id, &URI.char_unreserved?/1)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def get_ledger(params \\ %{}) do
    build_conn() |> get("/api/v1/ledger", params) |> json_response(200) |> Map.fetch!("data")
  end

  def get_guest_credit(guest_id, params \\ %{}) do
    build_conn()
    |> get("/api/v1/guests/#{URI.encode(guest_id, &URI.char_unreserved?/1)}/credit", params)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def get_operation(operation_id) do
    build_conn()
    |> get("/api/v1/operations/#{URI.encode(operation_id, &URI.char_unreserved?/1)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  def get_payment(payment_operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{URI.encode(payment_operation_id, &URI.char_unreserved?/1)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  @doc "Requests the daily finance report for `date` and returns the response."
  def get_daily_report_response(date) do
    params = if date, do: %{"date" => date}, else: %{}
    build_conn() |> get("/api/v1/finance/daily-report", params)
  end

  def get_daily_report(date),
    do: date |> get_daily_report_response() |> json_response(200) |> Map.fetch!("data")

  @doc "Each room's `{room_id, status, cash_paid_cents, credit_paid_cents}`, in original order."
  def room_funding(group_id) do
    for room <- get_group(group_id)["rooms"],
        do: {room["room_id"], room["status"], room["cash_paid_cents"], room["credit_paid_cents"]}
  end

  @doc "Every durable operation record, in commit order."
  def operation_records do
    GroupStay.Repo.query!("SELECT * FROM operation_records ORDER BY id").rows
  end

  @doc "Every row of every domain and finance reporting table, for asserting that nothing changed."
  def db_snapshot do
    for table <-
          ~w(groups group_rooms ledger_entries credit_lots credit_applications cash_allocations
             finance_reporting finance_postings finance_period_closes),
        into: %{} do
      %{rows: rows} = GroupStay.Repo.query!("SELECT * FROM #{table} ORDER BY id")
      {table, rows}
    end
  end
end
