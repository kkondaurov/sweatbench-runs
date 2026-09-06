defmodule GroupStay.Operations do
  @moduledoc """
  Builders for the raw JSON operations accepted by the partner batch API.
  """

  def open(overrides \\ %{}) do
    base = %{
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
    }

    Map.merge(base, overrides)
  end

  def payment(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-81",
      "amount_cents" => 10_000
    }

    Map.merge(base, overrides)
  end

  def reschedule(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-move",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-81",
      "new_arrival_on" => "2026-12-17"
    }

    Map.merge(base, overrides)
  end

  def cancel(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-81"
    }

    Map.merge(base, overrides)
  end

  def apply_credit(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-15",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }

    Map.merge(base, overrides)
  end

  def cancel_rooms(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-settle",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-81",
      "room_ids" => ["room-a"]
    }

    Map.merge(base, overrides)
  end

  def reduce(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-reduce",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-20",
      "payment_operation_id" => "op-pay",
      "amount_cents" => 2_000
    }

    Map.merge(base, overrides)
  end

  def charge_back(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-reverse",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-20",
      "payment_operation_id" => "op-pay"
    }

    Map.merge(base, overrides)
  end

  def transfer(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-transfer",
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-20",
      "source_group_id" => "group-81",
      "destination_group_id" => "group-92",
      "amount_cents" => 5_000
    }

    Map.merge(base, overrides)
  end

  def start_finance_reporting(overrides \\ %{}) do
    base = %{
      "operation_id" => "op-start-reporting",
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-15",
      "starts_on" => "2026-10-15"
    }

    Map.merge(base, overrides)
  end
end
