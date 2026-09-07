defmodule GroupStay.OperationFixtures do
  @moduledoc false

  def open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("open_group"),
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

  def start_reporting(overrides \\ %{}) do
    operation("start_finance_reporting", Map.merge(%{"starts_on" => "2026-11-01"}, overrides))
    |> Map.delete("group_id")
  end

  def close_period(overrides \\ %{}) do
    operation("close_finance_period", Map.merge(%{"period_end_on" => "2026-11-30"}, overrides))
    |> Map.delete("group_id")
  end

  def reschedule(overrides \\ %{}) do
    operation("reschedule_group", Map.merge(%{"new_arrival_on" => "2027-01-02"}, overrides))
  end

  def cancellation(overrides \\ %{}), do: operation("cancel_group", overrides)

  def room_cancellation(overrides \\ %{}),
    do: operation("cancel_rooms", Map.merge(%{"room_ids" => ["room-b"]}, overrides))

  def reduction(overrides \\ %{}) do
    operation(
      "reduce_cash_payment",
      Map.merge(%{"payment_operation_id" => "payment", "amount_cents" => 50}, overrides)
    )
    |> Map.delete("group_id")
  end

  def chargeback(overrides \\ %{}) do
    operation("charge_back_payment", Map.merge(%{"payment_operation_id" => "payment"}, overrides))
    |> Map.delete("group_id")
  end

  def transfer(overrides \\ %{}) do
    operation(
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => "group-81",
          "destination_group_id" => "destination",
          "amount_cents" => 50
        },
        overrides
      )
    )
    |> Map.delete("group_id")
  end

  defp operation(type, overrides) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id(type),
        "type" => type,
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  # Each fixture call describes a new operation. Reuse the returned map (or pass
  # an explicit operation_id) when exercising a retry or identifier conflict.
  def unique_operation_id(type), do: "#{type}-#{System.unique_integer([:positive, :monotonic])}"
end
