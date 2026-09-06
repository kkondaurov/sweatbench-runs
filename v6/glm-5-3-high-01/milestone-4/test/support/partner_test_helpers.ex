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

  def submit(conn, operations) do
    Phoenix.ConnTest.dispatch(conn, GroupStayWeb.Endpoint, :post, "/api/v1/partner-batches", %{
      "operations" => operations
    })
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
