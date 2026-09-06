defmodule GroupStay.TestOperations do
  @moduledoc """
  Builders for partner operations used across the test suite.

  Without an explicit `operation_id`, builders derive a stable identifier
  from the submitted content, so successive operations built inside a test
  never accidentally collide; most tests do not care about the identifier.
  Tests that exercise idempotency rules pass their own identifiers.
  """

  def open_group(overrides \\ %{}) do
    %{
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
    }
    |> Map.merge(overrides)
    |> put_generated_operation_id("open")
  end

  def pay(group_id, amount_cents, overrides \\ %{}) do
    %{
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
    |> Map.merge(overrides)
    |> put_generated_operation_id("pay")
  end

  def reschedule(group_id, new_arrival_on, overrides \\ %{}) do
    %{
      "type" => "reschedule_group",
      "occurred_on" => "2026-11-01",
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }
    |> Map.merge(overrides)
    |> put_generated_operation_id("move")
  end

  def cancel(group_id, occurred_on, overrides \\ %{}) do
    %{
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> Map.merge(overrides)
    |> put_generated_operation_id("cancel")
  end

  def apply_hotel_credit(group_id, amount_cents, overrides \\ %{}) do
    %{
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-01",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
    |> Map.merge(overrides)
    |> put_generated_operation_id("apply")
  end

  def batch(operations), do: %{"operations" => operations}

  # `:erlang.phash2` is deterministic for equal terms within a running node,
  # which is the lifetime over which test-built operations matter.
  defp put_generated_operation_id(op, prefix) do
    Map.put_new_lazy(op, "operation_id", fn ->
      prefix <> "-" <> Integer.to_string(:erlang.phash2(op), 36)
    end)
  end
end
