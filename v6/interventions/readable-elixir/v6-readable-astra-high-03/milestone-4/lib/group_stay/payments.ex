defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles durable cash payments and records provider corrections. All mutations
  share the partner operation transaction. Historical partner results are never
  rewritten; only current dispositions and held room slices change.
  """
  import Ecto.Query
  alias GroupStay.{Credit, Repo}
  alias GroupStay.Operations.Operation
  alias GroupStay.Payments.Payment
  alias GroupStay.Reservations.{Group, RoomAccounting, RoomFunding}

  def fetch_target(id, error_code) do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        {:ok, Repo.get_by!(Payment, payment_operation_id: id)}

      _ ->
        {:error, error_code}
    end
  end

  def statement(id) do
    with {:ok, payment} <- fetch_target(id, "payment_not_reconcilable"),
         do: {:ok, Payment.statement(payment)}
  end

  def record(group, operation) do
    Repo.insert!(%Payment{
      payment_operation_id: operation["operation_id"],
      original_group_id: group.group_id,
      recorded_cents: operation["amount_cents"]
    })

    RoomAccounting.fund(group, operation["amount_cents"], %{
      payment_operation_id: operation["operation_id"]
    })
  end

  @doc "Returns selected cash by original payment order, with legacy cash first."
  def contributions(cash_fundings) do
    amounts =
      cash_fundings
      |> Enum.group_by(& &1.payment_operation_id)
      |> Map.new(fn {id, slices} -> {id, Enum.sum(Enum.map(slices, & &1.amount_cents))} end)

    payment_ids = amounts |> Map.keys() |> Enum.reject(&is_nil/1)

    payment_order =
      Repo.all(
        from p in Payment,
          where: p.payment_operation_id in ^payment_ids,
          select: {p.payment_operation_id, p.id}
      )
      |> Map.new()

    Enum.sort_by(amounts, fn
      {nil, _} -> 0
      {id, _} -> Map.fetch!(payment_order, id)
    end)
  end

  def settle(contributions, disposition) do
    Enum.each(contributions, fn
      {nil, _amount} ->
        :ok

      {id, amount} ->
        Repo.update_all(from(p in Payment, where: p.payment_operation_id == ^id),
          inc: [{disposition, amount}]
        )
    end)
  end

  def reduce(payment, group, amount) do
    held = Payment.held(payment)

    cond do
      held == 0 ->
        {:error, "payment_not_reducible"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > held ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        remove_held(payment, amount)

        payment
        |> Ecto.Changeset.change(reduced_cents: payment.reduced_cents + amount)
        |> Repo.update!()

        changes = RoomAccounting.changes(group)

        {:ok, changes,
         %{
           payment_operation_id: payment.payment_operation_id,
           amount_cents: amount,
           outstanding_deposit_cents: Group.outstanding_deposit(changes)
         }}
    end
  end

  def charge_back(payment, group) do
    amount = payment.recorded_cents - payment.reduced_cents

    if amount == 0 or payment.charged_back_cents > 0 do
      {:error, "payment_not_chargeable"}
    else
      remove_held(payment, Payment.held(payment))
      Credit.claw_back(payment.payment_operation_id)

      payment
      |> Ecto.Changeset.change(
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: amount
      )
      |> Repo.update!()

      changes =
        Map.merge(RoomAccounting.changes(group), %{
          cash_refunded_cents: group.cash_refunded_cents - payment.refunded_cents,
          cash_retained_cents: group.cash_retained_cents - payment.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - payment.converted_to_credit_cents
        })

      {:ok, changes,
       %{
         payment_operation_id: payment.payment_operation_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit(changes)
       }}
    end
  end

  def totals_query do
    from p in Payment,
      select: %{
        cash_reduced_cents: coalesce(sum(p.reduced_cents), 0),
        cash_charged_back_cents: coalesce(sum(p.charged_back_cents), 0)
      }
  end

  defp remove_held(payment, amount) do
    slices =
      Repo.all(
        from f in RoomFunding,
          where: f.payment_operation_id == ^payment.payment_operation_id,
          order_by: [desc: f.id]
      )

    0 =
      Enum.reduce(slices, amount, fn slice, remaining ->
        removed = min(slice.amount_cents, remaining)
        if removed > 0, do: RoomAccounting.remove(slice, removed)
        remaining - removed
      end)
  end
end
