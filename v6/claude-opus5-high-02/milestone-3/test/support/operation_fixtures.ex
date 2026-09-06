defmodule GroupStay.OperationFixtures do
  @moduledoc """
  Raw partner operations, shaped exactly like the JSON a gateway submits.
  """

  def open_group(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      },
      overrides
    )
  end

  def record_cash_payment(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  def apply_hotel_credit(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  def reschedule_group(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-17"
      },
      overrides
    )
  end

  def cancel_group(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  def room(room_id, nightly_rate_cents),
    do: %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}

  defp merge(defaults, overrides), do: Map.merge(defaults, Map.new(overrides))
end
