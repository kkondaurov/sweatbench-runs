defmodule GroupStay.PartnerFixtures do
  @moduledoc false

  def operation(type, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{type}-#{System.unique_integer([:positive, :monotonic])}",
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

  def transfer_deposit(source, destination, amount, overrides \\ %{}) do
    operation("transfer_deposit", %{
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    })
    |> Map.delete("group_id")
    |> Map.merge(overrides)
  end

  def start_finance_reporting(overrides \\ %{}) do
    operation("start_finance_reporting", %{"starts_on" => "2026-10-03"})
    |> Map.delete("group_id")
    |> Map.merge(overrides)
  end

  def close_finance_period(period_end_on, overrides \\ %{}) do
    operation("close_finance_period", %{"period_end_on" => period_end_on})
    |> Map.delete("group_id")
    |> Map.merge(overrides)
  end
end
