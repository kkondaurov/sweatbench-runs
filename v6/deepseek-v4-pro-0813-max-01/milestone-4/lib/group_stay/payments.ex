defmodule GroupStay.Payments do
  @moduledoc """
  Per-payment reconciliation of recorded cash dispositions.
  """

  alias GroupStay.{Operation, PaymentDisposition, Repo, Room, RoomAllocation}

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

        held = held_cents(payment_operation_id)

        {:ok,
         %{
           "payment_operation_id" => payment_operation_id,
           "original_group_id" => record.payload["group_id"],
           "recorded_cents" => result["amount_cents"],
           "held_cents" => held,
           "refunded_cents" => field(disposition, :refunded_cents),
           "retained_cents" => field(disposition, :retained_cents),
           "converted_to_credit_cents" => field(disposition, :converted_cents),
           "reduced_cents" => field(disposition, :reduced_cents),
           "charged_back_cents" => field(disposition, :charged_back_cents)
         }}

      %Operation{} ->
        :not_reconcilable
    end
  end

  defp field(nil, _field), do: 0
  defp field(%PaymentDisposition{} = disposition, field), do: Map.fetch!(disposition, field)

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
