defmodule GroupStay.Reservations.Payments do
  @moduledoc "Current cash dispositions, independent of immutable partner results."
  import Ecto.Query, except: [update: 2]
  import GroupStay.Operations.Rejection, only: [reject: 1]
  alias GroupStay.{Repo, Operations.Operation}
  alias GroupStay.Reservations.{CreditEntitlement, HotelCredit, Payment, RoomAccounting}

  @dispositions ~w(refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

  def fetch(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        {:ok, Repo.get!(Payment, operation_id)}

      _ ->
        {:error, "payment_not_reconcilable"}
    end
  end

  def statement(operation_id) do
    case fetch(operation_id) do
      {:ok, payment} ->
        {:ok,
         payment
         |> Map.take([:payment_operation_id, :original_group_id, :recorded_cents | @dispositions])
         |> Map.put(:held_cents, held(payment))}

      error ->
        error
    end
  end

  def held(payment),
    do: payment.recorded_cents - Enum.sum(Enum.map(@dispositions, &Map.fetch!(payment, &1)))

  def record(group_id, operation_id, amount) do
    Repo.insert!(%Payment{
      original_group_id: group_id,
      payment_operation_id: operation_id,
      recorded_cents: amount
    })

    RoomAccounting.fund(group_id, amount, %{payment_operation_id: operation_id})
  end

  def reduce(payment, amount) do
    available = held(payment)
    if available == 0, do: reject("payment_not_reducible")
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > available, do: reject("reduction_exceeds_held_cash")

    RoomAccounting.remove_cash(payment.payment_operation_id, amount)
    update(payment, %{reduced_cents: payment.reduced_cents + amount})
    amount
  end

  def charge_back(payment) do
    amount = payment.recorded_cents - payment.reduced_cents
    if amount == 0 or payment.charged_back_cents > 0, do: reject("payment_not_chargeable")

    RoomAccounting.remove_cash(payment.payment_operation_id, held(payment))

    Repo.all(
      from e in CreditEntitlement, where: e.payment_operation_id == ^payment.payment_operation_id
    )
    |> Enum.each(&HotelCredit.claw_back(&1.credit_lot_id, &1.amount_cents))

    update(payment, %{
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: amount
    })

    amount
  end

  defp update(record, changes), do: record |> Ecto.Changeset.change(changes) |> Repo.update!()
end
