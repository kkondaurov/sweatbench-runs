defmodule GroupStay.Payments do
  @moduledoc """
  Reconciliation of a single recorded cash payment.

  A payment is addressed by the `operation_id` its durable record was committed
  under, so only cash the gateway recorded through this release can be corrected,
  reversed, or read back. Funding carried forward from before durable records
  existed has no payment identity at all.
  """

  alias GroupStay.Funding
  alias GroupStay.Funding.Allocation
  alias GroupStay.Operations
  alias GroupStay.Operations.Record

  @doc """
  Resolves the payment an operation addresses.

  Returns `{:error, :not_found}` when nothing was ever recorded under the
  identifier and `{:error, :not_a_payment}` when the record is not an applied
  cash payment.
  """
  def fetch_target(payment_operation_id) when is_binary(payment_operation_id) do
    with {:ok, record} <- Operations.fetch(payment_operation_id),
         %{} = target <- target(record) do
      {:ok, target}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_a_payment}
    end
  end

  defp target(%Record{type: "record_cash_payment", operation_id: operation_id, result: result})
       when is_map(result) do
    case result do
      %{"status" => "applied", "group_id" => group_id, "amount_cents" => recorded_cents}
      when is_binary(group_id) and is_integer(recorded_cents) ->
        %{
          payment_operation_id: operation_id,
          group_id: group_id,
          recorded_cents: recorded_cents
        }

      _other ->
        nil
    end
  end

  defp target(%Record{}), do: nil

  @doc "Cash from this payment that is still held on active rooms."
  def held_cash_cents(target), do: Funding.held_cash_cents(target.payment_operation_id)

  @doc """
  Cash from this payment a chargeback would still reverse.

  Zero means the payment has been fully reduced or already charged back.
  """
  def chargeable_cents(target) do
    cash = Funding.cash_by_disposition(target.payment_operation_id)

    Allocation.chargeable()
    |> Enum.map(&(Map.get(cash, &1) || 0))
    |> Enum.sum()
  end

  @doc """
  The current disposition of every cent this payment recorded.

  The six dispositions add up to the recorded amount, and reading them never
  changes anything.
  """
  def statement(target) do
    cash = Funding.cash_by_disposition(target.payment_operation_id)

    %{
      payment_operation_id: target.payment_operation_id,
      original_group_id: target.group_id,
      recorded_cents: target.recorded_cents,
      held_cents: disposition(cash, "held"),
      refunded_cents: disposition(cash, "refunded"),
      retained_cents: disposition(cash, "retained"),
      converted_to_credit_cents: disposition(cash, "converted"),
      reduced_cents: disposition(cash, "reduced"),
      charged_back_cents: disposition(cash, "charged_back")
    }
  end

  defp disposition(cash, name), do: Map.get(cash, name) || 0
end
