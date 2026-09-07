defmodule GroupStay.PartnerFixtures do
  @moduledoc false

  def operation(type, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{type}",
        "type" => type,
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  def open_group(overrides \\ %{}) do
    operation("open_group", %{
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-b", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
      ]
    })
    |> Map.merge(overrides)
  end
end
