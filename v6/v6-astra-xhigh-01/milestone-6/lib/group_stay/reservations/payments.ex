defmodule GroupStay.Reservations.Payments do
  @moduledoc "Current cash dispositions, independent of immutable partner results."
  import Ecto.Query, except: [update: 2]
  import GroupStay.Operations.Rejection, only: [reject: 1]
  alias GroupStay.{FinanceReporting, Repo, Operations.Operation}

  alias GroupStay.Reservations.{
    CreditEntitlement,
    FundingAllocation,
    HotelCredit,
    Payment,
    PaymentSettlement,
    RoomAccounting
  }

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
    # The payment and its current locations must come from the same snapshot.
    {:ok, result} = Repo.transaction(fn -> read_statement(operation_id) end)
    result
  end

  defp read_statement(operation_id) do
    case fetch(operation_id) do
      {:ok, payment} ->
        statement =
          payment
          |> Map.take([
            :payment_operation_id,
            :original_group_id,
            :recorded_cents | @dispositions
          ])
          |> Map.put(:held_cents, held(payment))

        {:ok,
         if(payment.transferred,
           do: Map.put(statement, :held_by_group, held_by_group(payment)),
           else: statement
         )}

      error ->
        error
    end
  end

  defp held_by_group(payment) do
    Repo.all(
      from a in FundingAllocation, where: a.payment_operation_id == ^payment.payment_operation_id
    )
    |> Enum.group_by(& &1.group_id)
    |> Enum.sort_by(fn {group_id, _} -> group_id end)
    |> Enum.map(fn {group_id, allocations} ->
      %{group_id: group_id, amount_cents: Enum.sum(Enum.map(allocations, & &1.amount_cents))}
    end)
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

  def reduce(payment, amount, posting) do
    available = held(payment)
    if available == 0, do: reject("payment_not_reducible")
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > available, do: reject("reduction_exceeds_held_cash")

    changes = remove_held(payment, amount, posting, :reduced_cents)
    update(payment, %{reduced_cents: payment.reduced_cents + amount})
    {amount, changes}
  end

  def charge_back(payment, posting) do
    amount = payment.recorded_cents - payment.reduced_cents
    if amount == 0 or payment.charged_back_cents > 0, do: reject("payment_not_chargeable")

    changes = remove_held(payment, held(payment), posting, :charged_back_cents)

    settlements =
      Repo.all(
        from s in PaymentSettlement,
          where: s.payment_operation_id == ^payment.payment_operation_id
      )

    changes =
      Enum.reduce(settlements, changes, fn settlement, changes ->
        for field <- [:refunded_cents, :retained_cents, :converted_to_credit_cents] do
          amount = Map.fetch!(settlement, field)
          FinanceReporting.cash(posting, settlement.group_id, field, -amount)
          FinanceReporting.cash(posting, settlement.group_id, :charged_back_cents, amount)
        end

        deltas = %{
          cash_refunded_cents: -settlement.refunded_cents,
          cash_retained_cents: -settlement.retained_cents,
          cash_converted_to_credit_cents: -settlement.converted_to_credit_cents
        }

        Map.update(changes, settlement.group_id, deltas, &Map.merge(&1, deltas))
      end)

    Repo.delete_all(
      from s in PaymentSettlement, where: s.payment_operation_id == ^payment.payment_operation_id
    )

    Repo.all(
      from e in CreditEntitlement, where: e.payment_operation_id == ^payment.payment_operation_id
    )
    |> Enum.each(&HotelCredit.claw_back(&1.credit_lot_id, &1.amount_cents, posting))

    update(payment, %{
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: amount
    })

    {amount, changes}
  end

  defp remove_held(payment, amount, posting, category) do
    RoomAccounting.remove_cash(payment.payment_operation_id, amount)
    |> Map.new(fn {group_id, removed} ->
      FinanceReporting.cash(posting, group_id, category, removed)
      {group_id, %{deposit_paid_cents: -removed}}
    end)
  end

  defp update(record, changes), do: record |> Ecto.Changeset.change(changes) |> Repo.update!()
end
