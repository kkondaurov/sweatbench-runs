defmodule GroupStay.Payments do
  @moduledoc """
  Reconciliation and provider corrections for durably recorded cash payments.

  Immutable receipts identify a payment; cash allocations describe its current
  disposition. Corrections never edit the receipt or reissue a historical refund.
  """
  import Ecto.Query
  alias GroupStay.{Accounting, Credits, Repo}
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Operations.Record

  def fetch(payment_id, invalid_code) do
    case Repo.get_by(Record, operation_id: payment_id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{type: "record_cash_payment", result: %{"status" => "applied"}} = payment ->
        {:ok, payment}

      _ ->
        {:error, invalid_code}
    end
  end

  def allocations(payment) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment.operation_id,
        order_by: a.id
    )
  end

  @statement_fields %{
    "held" => :held_cents,
    "refunded" => :refunded_cents,
    "retained" => :retained_cents,
    "converted_to_credit" => :converted_to_credit_cents,
    "reduced" => :reduced_cents,
    "charged_back" => :charged_back_cents
  }

  def statement(payment_id) do
    with {:ok, payment} <- fetch(payment_id, "payment_not_reconcilable") do
      allocations = allocations(payment)

      totals =
        Map.new(Accounting.dispositions(), fn disposition ->
          {Map.fetch!(@statement_fields, disposition),
           allocations |> Enum.filter(&(&1.disposition == disposition)) |> Accounting.sum()}
        end)

      {:ok,
       Map.merge(totals, %{
         payment_operation_id: payment.operation_id,
         original_group_id: payment.result["group_id"],
         recorded_cents: payment.result["amount_cents"]
       })}
    end
  end

  def reduce(payment, operation) do
    held = Enum.filter(allocations(payment), &(&1.disposition == "held"))
    amount = operation["amount_cents"]

    cond do
      Accounting.sum(held) == 0 ->
        {:error, "payment_not_reducible"}

      not Map.has_key?(operation, "amount_cents") ->
        {:error, "invalid_operation"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > Accounting.sum(held) ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        Accounting.remove_held(held, amount, "reduced")
        {:ok, %{amount_cents: amount}}
    end
  end

  def charge_back(payment) do
    allocations = allocations(payment)
    chargeable = Enum.reject(allocations, &(&1.disposition in ["reduced", "charged_back"]))

    if Enum.any?(allocations, &(&1.disposition == "charged_back")) or chargeable == [] do
      {:error, "payment_not_chargeable"}
    else
      {held, settled} = Enum.split_with(chargeable, &(&1.disposition == "held"))
      Accounting.remove_held(held, Accounting.sum(held), "charged_back")

      for allocation <- settled,
          do: Accounting.move(allocation, allocation.amount_cents, "charged_back")

      Credits.revoke(payment.operation_id)
      {:ok, %{charged_back_cents: Accounting.sum(chargeable)}}
    end
  end
end
