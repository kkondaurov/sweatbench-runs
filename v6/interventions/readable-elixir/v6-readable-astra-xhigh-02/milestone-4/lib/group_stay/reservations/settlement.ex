defmodule GroupStay.Reservations.Settlement do
  @moduledoc """
  Settles a selection of active rooms using the group's fixed cancellation policy.
  Selected cash receives one combined bonus; credit returns to its original lots.
  Other rooms keep their allocations, including any gaps left by reductions.
  """
  alias GroupStay.{Accounting, HotelCredit, Payments}
  alias GroupStay.Reservations.CancellationPolicy

  def cancel(group, operation, on) do
    rooms = Accounting.rooms(group.group_id)
    refundable? = CancellationPolicy.refundable?(group, on)
    method = Map.get(operation, "refund_method", "cash")

    with {:ok, selected} <- select_rooms(rooms, operation),
         :ok <- refund_method(method, refundable?) do
      allocations = Enum.flat_map(selected, & &1.allocations)
      disposition = disposition(refundable?, method)
      contributions = Payments.settle(allocations, disposition)
      cash = contributions |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      if refundable?, do: HotelCredit.restore(allocations, on)
      converted = if disposition == :converted_to_credit_cents, do: contributions, else: []
      issued = HotelCredit.issue(group, operation["operation_id"], converted, on)
      Accounting.cancel(selected)

      refunded = if disposition == :refunded_cents, do: cash, else: 0
      retained = if disposition == :retained_cents, do: cash, else: 0

      changes = %{
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents + if(converted == [], do: 0, else: cash)
      }

      result = %{
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: issued
      }

      result =
        if operation["type"] == "cancel_rooms",
          do: Map.put(result, :cancelled_room_ids, Enum.map(selected, & &1.room_id)),
          else: result

      {:ok, changes, result}
    end
  end

  defp select_rooms(rooms, %{"type" => "cancel_group"}) do
    {:ok, Enum.filter(rooms, &(&1.status == "active"))}
  end

  defp select_rooms(rooms, %{"room_ids" => [_ | _] = ids}) do
    selected = Enum.filter(rooms, &(&1.status == "active" and &1.room_id in ids))

    if length(selected) == length(ids),
      do: {:ok, selected},
      else: {:error, :invalid_rooms}
  end

  defp select_rooms(_rooms, %{"room_ids" => _ids}), do: {:error, :invalid_rooms}
  defp select_rooms(_rooms, _operation), do: {:error, :invalid_operation}

  defp refund_method("hotel_credit", false), do: {:error, :refund_method_not_available}
  defp refund_method(method, _refundable?) when method in ["cash", "hotel_credit"], do: :ok
  defp refund_method(_method, _refundable?), do: {:error, :invalid_operation}

  defp disposition(false, _method), do: :retained_cents
  defp disposition(true, "cash"), do: :refunded_cents
  defp disposition(true, "hotel_credit"), do: :converted_to_credit_cents
end
