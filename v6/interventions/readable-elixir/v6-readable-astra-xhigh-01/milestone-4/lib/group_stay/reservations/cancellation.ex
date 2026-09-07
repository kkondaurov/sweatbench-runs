defmodule GroupStay.Reservations.Cancellation do
  @moduledoc """
  Settles cash and hotel credit under a group's fixed cancellation policy.
  Cash converted to credit earns a bonus once; restored credit keeps its source
  lot and expiry. All settlement writes share the reservation's transaction.
  """

  alias GroupStay.{Credits, Finance, Payments}
  alias GroupStay.Reservations.CancellationPolicy

  def settle(group, rooms, operation, occurred_on) do
    refundable? = CancellationPolicy.refundable?(group, occurred_on)

    with {:ok, method} <- refund_method(operation.params),
         :ok <- available_method(method, refundable?),
         {:ok, settlement} <-
           settle_cash(group, rooms, operation, occurred_on, refundable?, method) do
      Credits.settle!(rooms, refundable?, occurred_on)
      {:ok, settlement}
    end
  end

  defp refund_method(params) do
    case Map.get(params, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp available_method("hotel_credit", false), do: {:error, "refund_method_not_available"}
  defp available_method(_method, _refundable?), do: :ok

  defp settle_cash(group, rooms, operation, occurred_on, true, "hotel_credit") do
    allocations = Payments.held_on_rooms(rooms)

    with {:ok, lot} <- Credits.issue(group, allocations, operation, occurred_on) do
      cash = Enum.sum(Enum.map(allocations, & &1.amount_cents))
      issued = if lot, do: lot.issued_cents, else: 0
      Payments.settle!(allocations, :converted_to_credit, if(lot, do: lot.id))
      Finance.record!(operation, occurred_on, :credit_conversion, cash)
      {:ok, %{refunded_cents: 0, retained_cents: 0, credit_issued_cents: issued}}
    end
  end

  defp settle_cash(_group, rooms, operation, occurred_on, refundable?, "cash") do
    allocations = Payments.held_on_rooms(rooms)
    cash = Enum.sum(Enum.map(allocations, & &1.amount_cents))
    refunded = if refundable?, do: cash, else: 0
    retained = if refundable?, do: 0, else: cash
    Payments.settle!(allocations, if(refundable?, do: :refunded, else: :retained))
    Finance.record!(operation, occurred_on, :refund, refunded)
    Finance.record!(operation, occurred_on, :retention, retained)
    {:ok, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: 0}}
  end
end
