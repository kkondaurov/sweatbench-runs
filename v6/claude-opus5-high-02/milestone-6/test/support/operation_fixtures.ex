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

  def cancel_rooms(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  def reduce_cash_payment(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 500
      },
      overrides
    )
  end

  def charge_back_payment(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  def transfer_deposit(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-08",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  def start_finance_reporting(overrides \\ %{}) do
    merge(
      %{
        "operation_id" => "op-start-reporting",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
  end

  def room(room_id, nightly_rate_cents),
    do: %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}

  defp merge(defaults, overrides), do: Map.merge(defaults, Map.new(overrides))
end
