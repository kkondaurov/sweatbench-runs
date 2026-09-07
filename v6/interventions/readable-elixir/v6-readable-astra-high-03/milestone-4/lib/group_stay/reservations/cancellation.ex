defmodule GroupStay.Reservations.Cancellation do
  @moduledoc """
  Settles selected active rooms under the group's fixed policy. Cash earns one
  combined bonus; restored credit keeps its original lot and expiry. Settlement
  updates both payment dispositions and the group's cumulative cash totals.
  """
  alias GroupStay.{Credit, Payments, Repo}
  alias GroupStay.Reservations.{CancellationPolicy, RoomAccounting}

  def settle(group, operation, on) do
    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, on)

    with {:ok, room_ids} <- selected_rooms(group, operation),
         :ok <- validate_method(method, refundable?) do
      {credit, cash} =
        group
        |> RoomAccounting.held()
        |> Enum.filter(&(&1.room_id in room_ids))
        |> Enum.split_with(&(&1.credit_lot_id != nil))

      contributions = Payments.contributions(cash)
      cash_cents = Enum.sum(Enum.map(cash, & &1.amount_cents))
      disposition = disposition(method, refundable?)

      with {:ok, issued} <-
             issue_credit(group, operation["operation_id"], disposition, cash_cents, on) do
        if issued > 0, do: Credit.assign_entitlements(operation["operation_id"], contributions)
        Payments.settle(contributions, disposition)
        Credit.settle(credit, refundable?, on)
        Enum.each(credit ++ cash, &Repo.delete!/1)

        refunded = if disposition == :refunded_cents, do: cash_cents, else: 0
        retained = if disposition == :retained_cents, do: cash_cents, else: 0
        converted = if disposition == :converted_to_credit_cents, do: cash_cents, else: 0

        changes =
          Map.merge(RoomAccounting.changes(group, room_ids), %{
            cash_refunded_cents: group.cash_refunded_cents + refunded,
            cash_retained_cents: group.cash_retained_cents + retained,
            cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
          })

        result = %{
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: issued
        }

        result =
          if operation["type"] == "cancel_rooms",
            do: Map.put(result, :cancelled_room_ids, room_ids),
            else: result

        {:ok, changes, result}
      end
    end
  end

  defp selected_rooms(group, %{"type" => "cancel_group"}),
    do: {:ok, group.rooms |> Enum.filter(&(&1.status == "active")) |> Enum.map(& &1.room_id)}

  defp selected_rooms(group, %{"room_ids" => ids}) when is_list(ids) and ids != [] do
    active_ids = group.rooms |> Enum.filter(&(&1.status == "active")) |> Enum.map(& &1.room_id)

    if length(Enum.uniq(ids)) == length(ids) and Enum.all?(ids, &(&1 in active_ids)),
      do: {:ok, Enum.filter(active_ids, &(&1 in ids))},
      else: {:error, "invalid_rooms"}
  end

  defp selected_rooms(_, _), do: {:error, "invalid_rooms"}
  defp validate_method("hotel_credit", false), do: {:error, "refund_method_not_available"}
  defp validate_method(method, _) when method in ["cash", "hotel_credit"], do: :ok
  defp validate_method(_, _), do: {:error, "invalid_operation"}
  defp disposition("hotel_credit", true), do: :converted_to_credit_cents
  defp disposition("cash", true), do: :refunded_cents
  defp disposition(_, false), do: :retained_cents

  defp issue_credit(group, operation_id, :converted_to_credit_cents, cash, on),
    do: Credit.issue(group.guest_id, operation_id, cash, on)

  defp issue_credit(_, _, _, _, _), do: {:ok, 0}
end
