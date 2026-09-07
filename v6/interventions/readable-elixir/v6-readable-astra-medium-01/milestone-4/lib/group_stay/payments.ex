defmodule GroupStay.Payments do
  @moduledoc """
  Reconciliation and provider corrections for journaled cash payments. The
  original journal entry is immutable; current dispositions live in accounting.
  Revision checks use the original payment's group, including cancelled groups.
  """
  alias GroupStay.{Repo, Accounting, Reservations}
  alias GroupStay.Operations.Entry
  alias GroupStay.Reservations.Group

  def statement(id) do
    with {:ok, payment} <- find(id, "payment_not_reconcilable") do
      {:ok,
       Accounting.dispositions(id)
       |> Map.merge(%{
         payment_operation_id: id,
         original_group_id: payment.result["group_id"],
         recorded_cents: payment.result["amount_cents"]
       })}
    end
  end

  def change(op) do
    chargeback? = op["type"] == "charge_back_payment"
    unavailable = if chargeback?, do: "payment_not_chargeable", else: "payment_not_reducible"

    with {:ok, payment} <- find(op["payment_operation_id"], unavailable) do
      group = Reservations.get_group(payment.result["group_id"])

      cond do
        is_nil(group) ->
          rejected("group_not_found")

        Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
          rejected("stale_revision")
          |> Map.merge(%{
            group_id: group.group_id,
            expected_revision: op["expected_revision"],
            actual_revision: group.revision
          })

        true ->
          correct(group, op, chargeback?)
      end
    else
      {:error, code} -> rejected(code)
    end
  end

  defp correct(group, op, true) do
    totals = Accounting.dispositions(op["payment_operation_id"])

    remaining =
      totals.held_cents + totals.refunded_cents + totals.retained_cents +
        totals.converted_to_credit_cents

    if totals.charged_back_cents > 0 or remaining == 0 do
      rejected("payment_not_chargeable")
    else
      {updated, amount} = Accounting.charge_back(group, op["payment_operation_id"])
      applied(updated, op, %{charged_back_cents: amount})
    end
  end

  defp correct(group, op, false) do
    held = Accounting.dispositions(op["payment_operation_id"]).held_cents
    amount = op["amount_cents"]

    cond do
      held == 0 ->
        rejected("payment_not_reducible")

      not Map.has_key?(op, "amount_cents") ->
        rejected("invalid_operation")

      not is_integer(amount) or amount <= 0 ->
        rejected("invalid_amount")

      amount > held ->
        rejected("reduction_exceeds_held_cash")

      true ->
        updated = Accounting.reduce_payment(group, op["payment_operation_id"], amount)
        applied(updated, op, %{amount_cents: amount})
    end
  end

  defp find(id, code) do
    case Repo.get_by(Entry, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Entry{type: "record_cash_payment", result: %{"status" => "applied"}} = entry ->
        {:ok, entry}

      _ ->
        {:error, code}
    end
  end

  defp rejected(code), do: %{status: "rejected", code: code}

  defp applied(group, op, fields) do
    Map.merge(fields, %{
      status: "applied",
      group_id: group.group_id,
      revision: group.revision,
      payment_operation_id: op["payment_operation_id"],
      outstanding_deposit_cents: Group.outstanding(group)
    })
  end
end
