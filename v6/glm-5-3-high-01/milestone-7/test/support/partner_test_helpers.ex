defmodule GroupStay.PartnerTestHelpers do
  @moduledoc false

  def open_group_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
    }
    |> Map.merge(attrs)
  end

  def payment_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 5000
    }
    |> Map.merge(attrs)
  end

  def reschedule_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-move",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-1",
      "new_arrival_on" => "2026-12-15"
    }
    |> Map.merge(attrs)
  end

  def cancel_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => "group-1"
    }
    |> Map.merge(attrs)
  end

  def apply_credit_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => "group-1",
      "amount_cents" => 2000
    }
    |> Map.merge(attrs)
  end

  def cancel_rooms_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-cancel-rooms",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-11-26",
      "group_id" => "group-1",
      "room_ids" => ["room-a"]
    }
    |> Map.merge(attrs)
  end

  def reduce_cash_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "op-pay",
      "amount_cents" => 1000
    }
    |> Map.merge(attrs)
  end

  def charge_back_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-chargeback",
      "type" => "charge_back_payment",
      "payment_operation_id" => "op-pay"
    }
    |> Map.merge(attrs)
  end

  def transfer_deposit_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-transfer",
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-07",
      "source_group_id" => "group-1",
      "destination_group_id" => "group-2",
      "amount_cents" => 2000
    }
    |> Map.merge(attrs)
  end

  def start_reporting_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-11-01"
    }
    |> Map.merge(attrs)
  end

  def close_period_operation(attrs \\ %{}) do
    %{
      "operation_id" => "op-close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-11-10"
    }
    |> Map.merge(attrs)
  end

  def zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  def submit(conn, operations) do
    Phoenix.ConnTest.dispatch(conn, GroupStayWeb.Endpoint, :post, "/api/v1/partner-batches", %{
      "operations" => operations
    })
  end

  def daily_report(conn, date) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/finance/daily-report",
      %{"date" => date}
    )
  end

  def report_data(conn, date) do
    conn = daily_report(conn, date)
    Phoenix.ConnTest.json_response(conn, 200)["data"]
  end

  def cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  def apply_operations!(conn, operations) do
    conn = submit(conn, operations)
    results = json_response(conn, 200)["results"]

    Enum.each(results, fn result ->
      unless result["status"] == "applied" do
        ExUnit.Assertions.flunk("expected operation to be applied, got: #{inspect(result)}")
      end
    end)

    results
  end

  defp json_response(conn, status) do
    Phoenix.ConnTest.json_response(conn, status)
  end
end
