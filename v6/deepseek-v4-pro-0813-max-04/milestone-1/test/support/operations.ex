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
end
