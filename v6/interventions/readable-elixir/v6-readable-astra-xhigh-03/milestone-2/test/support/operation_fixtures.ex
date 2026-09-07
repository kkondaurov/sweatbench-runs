defmodule GroupStay.OperationFixtures do
  @moduledoc false

  def open_group(overrides \\ %{}) do
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
      overrides
    )
  end

  def payment(overrides \\ %{}) do
    operation("record_cash_payment", Map.merge(%{"amount_cents" => 5_000}, overrides))
  end

  def credit_application(overrides \\ %{}) do
    operation("apply_hotel_credit", Map.merge(%{"amount_cents" => 5_000}, overrides))
  end

  def reschedule(overrides \\ %{}) do
    operation("reschedule_group", Map.merge(%{"new_arrival_on" => "2027-01-02"}, overrides))
  end

  def cancellation(overrides \\ %{}), do: operation("cancel_group", overrides)

  defp operation(type, overrides) do
    Map.merge(
      %{
        "operation_id" => type <> "-1",
        "type" => type,
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end
end
