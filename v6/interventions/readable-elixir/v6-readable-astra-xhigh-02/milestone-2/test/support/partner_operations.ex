defmodule GroupStay.PartnerOperations do
  @moduledoc false

  def open_group(attributes \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-b", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
        ]
      },
      attributes
    )
  end

  def operation(type, attributes \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-1",
        "type" => type,
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      attributes
    )
  end

  def payment(attributes \\ %{}) do
    operation("record_cash_payment", Map.merge(%{"amount_cents" => 1_000}, attributes))
  end

  def reschedule(attributes \\ %{}) do
    operation("reschedule_group", Map.merge(%{"new_arrival_on" => "2027-01-10"}, attributes))
  end

  def cancellation(attributes \\ %{}), do: operation("cancel_group", attributes)

  def credit_payment(attributes \\ %{}) do
    operation("apply_hotel_credit", Map.merge(%{"amount_cents" => 1_000}, attributes))
  end
end
