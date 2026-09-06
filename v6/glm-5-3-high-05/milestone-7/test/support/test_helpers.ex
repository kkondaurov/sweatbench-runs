defmodule GroupStayWeb.TestHelpers do
  @moduledoc """
  Helpers for partner API tests.
  """

  import Phoenix.ConnTest
  import ExUnit.Assertions

  @endpoint GroupStayWeb.Endpoint

  def post_batch(conn \\ Phoenix.ConnTest.build_conn(), operations) do
    Phoenix.ConnTest.post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  # Every operation submitted by the gateway carries its own operation_id, so
  # generated defaults are unique per call. Tests that care pass their own.
  defp unique_operation_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  def open_group_operation(attrs \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      Map.new(attrs)
    )
  end

  def record_cash_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      Map.new(attrs)
    )
  end

  def reschedule_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-move"),
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      Map.new(attrs)
    )
  end

  def cancel_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      Map.new(attrs)
    )
  end

  def apply_hotel_credit_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      Map.new(attrs)
    )
  end

  def cancel_rooms_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-cancel-rooms"),
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      Map.new(attrs)
    )
  end

  def reduce_cash_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-reduce"),
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-01",
        "payment_operation_id" => "op-pay-1",
        "amount_cents" => 1000
      },
      Map.new(attrs)
    )
  end

  def charge_back_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-chargeback"),
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-01",
        "payment_operation_id" => "op-pay-1"
      },
      Map.new(attrs)
    )
  end

  def transfer_deposit_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-transfer"),
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-01",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 1000
      },
      Map.new(attrs)
    )
  end

  def start_reporting_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-start"),
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => "2026-11-01"
      },
      Map.new(attrs)
    )
  end

  def close_period_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-close"),
        "type" => "close_finance_period",
        "occurred_on" => "2026-11-01",
        "period_end_on" => "2026-11-05"
      },
      Map.new(attrs)
    )
  end

  def get_daily_report(conn \\ Phoenix.ConnTest.build_conn(), date \\ nil) do
    case date do
      nil -> Phoenix.ConnTest.get(conn, "/api/v1/finance/daily-report")
      date -> Phoenix.ConnTest.get(conn, "/api/v1/finance/daily-report?date=#{date}")
    end
  end

  @doc "Posts a single operation and returns the sole result."
  def apply_one!(conn \\ Phoenix.ConnTest.build_conn(), operation) do
    conn = post_batch(conn, [operation])
    assert %{status: 200} = conn
    %{"results" => [result]} = json_response(conn, 200)
    result
  end

  @doc "Opens the canonical group and returns the applied result."
  def open_group!(conn \\ Phoenix.ConnTest.build_conn(), attrs \\ %{}) do
    result = apply_one!(conn, open_group_operation(attrs))
    assert %{"status" => "applied"} = result
    result
  end

  def get_group(conn \\ Phoenix.ConnTest.build_conn(), group_id) do
    Phoenix.ConnTest.get(conn, "/api/v1/groups/#{group_id}")
  end

  def get_ledger(conn \\ Phoenix.ConnTest.build_conn(), on \\ nil) do
    case on do
      nil -> Phoenix.ConnTest.get(conn, "/api/v1/ledger")
      on -> Phoenix.ConnTest.get(conn, "/api/v1/ledger?on=#{on}")
    end
  end

  def get_guest_credit(conn \\ Phoenix.ConnTest.build_conn(), guest_id, on \\ nil) do
    case on do
      nil -> Phoenix.ConnTest.get(conn, "/api/v1/guests/#{guest_id}/credit")
      on -> Phoenix.ConnTest.get(conn, "/api/v1/guests/#{guest_id}/credit?on=#{on}")
    end
  end

  def get_payment(conn \\ Phoenix.ConnTest.build_conn(), payment_operation_id) do
    Phoenix.ConnTest.get(conn, "/api/v1/payments/#{payment_operation_id}")
  end
end
