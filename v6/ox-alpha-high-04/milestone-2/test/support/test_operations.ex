defmodule GroupStay.TestOperations do
  @moduledoc """
  Builders for partner operations used across the test suite.
  """

  def open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  def pay(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def reschedule(group_id, new_arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival_on
      },
      overrides
    )
  end

  def cancel(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  def apply_hotel_credit(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def batch(operations), do: %{"operations" => operations}
end
