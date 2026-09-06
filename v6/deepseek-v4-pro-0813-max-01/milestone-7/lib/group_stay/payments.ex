defmodule GroupStay.Payments do
  @moduledoc """
  Per-payment reconciliation of recorded cash dispositions.
  """

  alias GroupStay.{Group, Operation, PaymentDisposition, Repo, Room, RoomAllocation}

  import Ecto.Query

  @doc """
  The current disposition of a durably recorded, applied cash payment.

  Returns `{:ok, map}` for an applied cash payment, `:not_found` when no
  durable record exists, and `:not_reconcilable` when the record exists but is
  not an applied cash payment.
  """
  @spec reconcile(String.t()) :: {:ok, map()} | :not_found | :not_reconcilable
  def reconcile(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %Operation{type: "record_cash_payment", result: %{"status" => "applied"} = result} = record ->
        disposition = Repo.get_by(PaymentDisposition, payment_operation_id: payment_operation_id)

        statement = %{
          "payment_operation_id" => payment_operation_id,
          "original_group_id" => record.payload["group_id"],
          "recorded_cents" => result["amount_cents"],
          "held_cents" => held_cents(payment_operation_id),
          "refunded_cents" => field(disposition, :refunded_cents),
          "retained_cents" => field(disposition, :retained_cents),
          "converted_to_credit_cents" => field(disposition, :converted_cents),
          "reduced_cents" => field(disposition, :reduced_cents),
          "charged_back_cents" => field(disposition, :charged_back_cents)
        }

        # Once any of a payment's cash has participated in a transfer, the
        # statement carries the current held balance per group.
        statement =
          if transferred?(disposition) do
            Map.put(statement, "held_by_group", held_by_group(payment_operation_id))
          else
            statement
          end

        {:ok, statement}

      %Operation{} ->
        :not_reconcilable
    end
  end

  defp field(nil, _field), do: 0
  defp field(%PaymentDisposition{} = disposition, field), do: Map.fetch!(disposition, field)

  defp transferred?(nil), do: false

  defp transferred?(%PaymentDisposition{} = disposition),
    do: disposition.participated_in_transfer

  defp held_by_group(payment_operation_id) do
    from(a in RoomAllocation,
      join: r in Room,
      on: r.id == a.room_id,
      join: g in Group,
      on: g.id == a.group_id,
      where:
        a.kind == "cash" and a.payment_operation_id == ^payment_operation_id and
          r.status == "active",
      group_by: g.group_id,
      select: {g.group_id, type(sum(a.amount_cents), :integer)},
      order_by: g.group_id
    )
    |> Repo.all()
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp held_cents(payment_operation_id) do
    from(a in RoomAllocation,
      join: r in Room,
      on: r.id == a.room_id,
      where:
        a.kind == "cash" and a.payment_operation_id == ^payment_operation_id and
          r.status == "active",
      select: type(coalesce(sum(a.amount_cents), 0), :integer)
    )
    |> Repo.one()
  end
end
