defmodule GroupStay.ReservationFixtures do
  def open_operation(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{Ecto.UUID.generate()}",
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
      attrs
    )
  end

  def operation(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{Ecto.UUID.generate()}",
        "type" => type,
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      attrs
    )
  end
end
