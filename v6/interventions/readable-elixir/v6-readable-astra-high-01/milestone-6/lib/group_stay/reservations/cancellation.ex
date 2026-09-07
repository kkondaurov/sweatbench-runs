defmodule GroupStay.Reservations.Cancellation do
  @moduledoc """
  Settles the selected active rooms under the group's fixed cancellation policy.

  Cash is settled as one amount so a credit bonus is rounded once. Credit
  redemptions return to their original lots, where clawback and expiry apply.
  Full cancellation uses the same path with all remaining active rooms.
  """
  alias GroupStay.{Accounting, Credits}
  alias GroupStay.Reservations.CancellationPolicy

  def settle(group, operation, occurred_on) do
    type = operation["type"]
    active_ids = group.rooms |> Enum.filter(&(&1.status == "active")) |> Enum.map(& &1.room_id)
    selected = if type == "cancel_group", do: active_ids, else: operation["room_ids"]
    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, occurred_on)

    cond do
      type == "cancel_rooms" and not Map.has_key?(operation, "room_ids") ->
        {:error, "invalid_operation"}

      not is_list(selected) or selected == [] or
        length(Enum.uniq(selected)) != length(selected) or
          not Enum.all?(selected, &(&1 in active_ids)) ->
        {:error, "invalid_rooms"}

      method not in ["cash", "hotel_credit"] ->
        {:error, "invalid_operation"}

      method == "hotel_credit" and not refundable? ->
        {:error, "refund_method_not_available"}

      true ->
        selected = Enum.filter(active_ids, &(&1 in selected))

        cash =
          Accounting.cash(group.group_id)
          |> Enum.filter(&(&1.disposition == "held" and &1.room_id in selected))

        disposition =
          cond do
            not refundable? -> "retained"
            method == "hotel_credit" -> "converted_to_credit"
            true -> "refunded"
          end

        issued =
          if method == "hotel_credit",
            do: Credits.issue(group, operation["operation_id"], occurred_on, cash),
            else: 0

        for allocation <- cash,
            do: Accounting.move(allocation, allocation.amount_cents, disposition)

        Credits.settle(group, selected, refundable?, occurred_on)

        group = Accounting.refresh(group, selected)

        fields = %{
          refunded_cents: if(disposition == "refunded", do: Accounting.sum(cash), else: 0),
          retained_cents: if(disposition == "retained", do: Accounting.sum(cash), else: 0),
          credit_issued_cents: issued
        }

        fields =
          if type == "cancel_rooms",
            do: Map.put(fields, :cancelled_room_ids, selected),
            else: fields

        {:ok, group, fields}
    end
  end
end
