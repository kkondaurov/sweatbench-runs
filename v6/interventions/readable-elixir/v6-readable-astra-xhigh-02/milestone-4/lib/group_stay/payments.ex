defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles recorded cash and changes its dispositions without rewriting receipts.

  All writes share the partner operation's transaction. Payment identity comes
  from an applied cash operation's retained type, never from a caller's group ID
  or the shape of a result shared with credit applications.
  """
  alias Ecto.Changeset
  alias GroupStay.{Accounting, HotelCredit, Repo}
  alias GroupStay.Accounting.CashPayment
  alias GroupStay.Operations.Operation

  def statement(operation_id) do
    with {:ok, payment} <- fetch(operation_id, :payment_not_reconcilable) do
      {:ok,
       payment
       |> Map.take([
         :payment_operation_id,
         :recorded_cents,
         :refunded_cents,
         :retained_cents,
         :converted_to_credit_cents,
         :reduced_cents,
         :charged_back_cents
       ])
       |> Map.put(:original_group_id, payment.group_id)
       |> Map.put(:held_cents, CashPayment.held_cents(payment))}
    end
  end

  def fetch(operation_id, invalid_code) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      %Operation{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        {:ok, Repo.get_by!(CashPayment, payment_operation_id: operation_id)}

      _ ->
        {:error, invalid_code}
    end
  end

  def record(group, operation) do
    payment =
      Repo.insert!(%CashPayment{
        group_id: group.group_id,
        payment_operation_id: operation["operation_id"],
        recorded_cents: operation["amount_cents"]
      })

    Accounting.fund(group.group_id, payment.recorded_cents, cash_payment_id: payment.id)
  end

  @doc "Settles selected cash allocations and returns contributions in funding order."
  def settle(allocations, disposition) do
    contributions =
      allocations
      |> Enum.reject(&is_nil(&1.cash_payment_id))
      |> Enum.group_by(& &1.cash_payment_id, & &1.amount_cents)
      |> Enum.map(fn {id, amounts} -> {id, Enum.sum(amounts)} end)
      |> Enum.sort_by(&elem(&1, 0))

    for {id, amount} <- contributions do
      payment = Repo.get!(CashPayment, id)
      change(payment, %{disposition => Map.fetch!(payment, disposition) + amount})
    end

    contributions
  end

  def reduce(payment, amount) do
    held = CashPayment.held_cents(payment)

    cond do
      held == 0 ->
        {:error, :payment_not_reducible}

      not is_integer(amount) or amount <= 0 ->
        {:error, :invalid_amount}

      amount > held ->
        {:error, :reduction_exceeds_held_cash}

      true ->
        Accounting.remove_cash(payment.id, amount)
        change(payment, %{reduced_cents: payment.reduced_cents + amount})
        :ok
    end
  end

  def charge_back(payment) do
    amount = payment.recorded_cents - payment.reduced_cents

    if amount == 0 or payment.charged_back_cents > 0 do
      {:error, :payment_not_chargeable}
    else
      Accounting.remove_cash(payment.id, CashPayment.held_cents(payment))
      HotelCredit.revoke(payment.id)

      change(payment, %{
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: amount
      })

      {:ok, amount}
    end
  end

  def cash_totals do
    initial = %{
      cash_held_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      cash_reduced_cents: 0,
      cash_charged_back_cents: 0
    }

    # Summing in Elixir keeps totals exact beyond SQLite's signed 64-bit SUM limit.
    Enum.reduce(Repo.all(CashPayment), initial, fn payment, totals ->
      %{
        cash_held_cents: totals.cash_held_cents + CashPayment.held_cents(payment),
        cash_refunded_cents: totals.cash_refunded_cents + payment.refunded_cents,
        cash_retained_cents: totals.cash_retained_cents + payment.retained_cents,
        cash_converted_to_credit_cents:
          totals.cash_converted_to_credit_cents + payment.converted_to_credit_cents,
        cash_reduced_cents: totals.cash_reduced_cents + payment.reduced_cents,
        cash_charged_back_cents: totals.cash_charged_back_cents + payment.charged_back_cents
      }
    end)
  end

  defp change(payment, attributes), do: payment |> Changeset.change(attributes) |> Repo.update!()
end
