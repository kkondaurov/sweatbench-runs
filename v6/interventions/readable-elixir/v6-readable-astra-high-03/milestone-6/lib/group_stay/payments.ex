defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles durable cash payments and records provider corrections. All mutations
  share the partner operation transaction. Historical partner results are never
  rewritten; only current dispositions and held room slices change.
  """
  import Ecto.Query
  alias GroupStay.{Credit, Repo}
  alias GroupStay.Finance.Journal
  alias GroupStay.Operations.Operation
  alias GroupStay.Payments.{Payment, Settlement}
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
    # Both reads share a snapshot, even when a transfer commits concurrently.
    {:ok, result} =
      Repo.transaction(fn ->
        with {:ok, payment} <- fetch_target(id, "payment_not_reconcilable") do
          statement = Payment.statement(payment)

          statement =
            if payment.transferred,
              do: Map.put(statement, :held_by_group, held_by_group(id)),
              else: statement

          {:ok, statement}
        end
      end)

    result
  end

  def mark_transferred(payment_operation_id) do
    Repo.update_all(from(p in Payment, where: p.payment_operation_id == ^payment_operation_id),
      set: [transferred: true]
    )
  end

  defp held_by_group(payment_operation_id) do
    Repo.all(
      from f in RoomFunding,
        where: f.payment_operation_id == ^payment_operation_id,
        group_by: f.group_id,
        order_by: f.group_id,
        select: %{group_id: f.group_id, amount_cents: sum(f.amount_cents)}
    )
  end

  def record(group, operation, reporting \\ nil) do
    Repo.insert!(%Payment{
      payment_operation_id: operation["operation_id"],
      original_group_id: group.group_id,
      recorded_cents: operation["amount_cents"]
    })

    Journal.cash(reporting, group, :received_cents, operation["amount_cents"])

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

  def settle(group_id, contributions, disposition) do
    Enum.each(contributions, fn
      {nil, _amount} ->
        :ok

      {id, amount} ->
        Repo.update_all(from(p in Payment, where: p.payment_operation_id == ^id),
          inc: [{disposition, amount}]
        )

        Repo.insert!(
          struct!(Settlement, %{
            disposition => amount,
            :payment_operation_id => id,
            :group_id => group_id
          }),
          on_conflict: [inc: [{disposition, amount}]],
          conflict_target: [:payment_operation_id, :group_id]
        )
    end)
  end

  def reduce(payment, group, amount, reporting \\ nil) do
    held = Payment.held(payment)

    cond do
      held == 0 ->
        {:error, "payment_not_reducible"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > held ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        affected_groups = remove_held(payment, amount, reporting, :reduced_cents)

        payment
        |> Ecto.Changeset.change(reduced_cents: payment.reduced_cents + amount)
        |> Repo.update!()

        groups = RoomAccounting.refresh_groups([group.group_id | affected_groups])
        group = Map.fetch!(groups, group.group_id)

        {:ok,
         %{
           group_id: group.group_id,
           revision: group.revision,
           payment_operation_id: payment.payment_operation_id,
           amount_cents: amount,
           outstanding_deposit_cents: Group.outstanding_deposit(group)
         }}
    end
  end

  def charge_back(payment, group, reporting \\ nil) do
    amount = payment.recorded_cents - payment.reduced_cents

    if amount == 0 or payment.charged_back_cents > 0 do
      {:error, "payment_not_chargeable"}
    else
      affected_groups =
        remove_held(payment, Payment.held(payment), reporting, :charged_back_cents)

      settlement_changes = reverse_settlements(payment, reporting)
      Credit.claw_back(payment.payment_operation_id, reporting)

      payment
      |> Ecto.Changeset.change(
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: amount
      )
      |> Repo.update!()

      groups =
        RoomAccounting.refresh_groups(
          [group.group_id | affected_groups] ++ Map.keys(settlement_changes),
          settlement_changes
        )

      group = Map.fetch!(groups, group.group_id)

      {:ok,
       %{
         group_id: group.group_id,
         revision: group.revision,
         payment_operation_id: payment.payment_operation_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit(group)
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

  defp remove_held(payment, amount, reporting, disposition) do
    slices =
      Repo.all(
        from f in RoomFunding,
          where: f.payment_operation_id == ^payment.payment_operation_id,
          order_by: [desc: f.id]
      )

    {0, affected_groups} =
      Enum.reduce(slices, {amount, []}, fn slice, {remaining, affected_groups} ->
        removed = min(slice.amount_cents, remaining)

        if removed > 0 do
          Journal.cash_for_group(reporting, slice.group_id, disposition, removed)
          RoomAccounting.remove(slice, removed)
          {remaining - removed, [slice.group_id | affected_groups]}
        else
          {remaining, affected_groups}
        end
      end)

    affected_groups
  end

  defp reverse_settlements(payment, reporting) do
    Repo.all(from s in Settlement, where: s.payment_operation_id == ^payment.payment_operation_id)
    |> Map.new(fn settlement ->
      group = Repo.get!(Group, settlement.group_id)
      Repo.delete!(settlement)

      for kind <- [:refunded_cents, :retained_cents, :converted_to_credit_cents] do
        amount = Map.fetch!(settlement, kind)
        Journal.cash(reporting, group, kind, -amount)
        Journal.cash(reporting, group, :charged_back_cents, amount)
      end

      {group.group_id,
       %{
         cash_refunded_cents: group.cash_refunded_cents - settlement.refunded_cents,
         cash_retained_cents: group.cash_retained_cents - settlement.retained_cents,
         cash_converted_to_credit_cents:
           group.cash_converted_to_credit_cents - settlement.converted_to_credit_cents
       }}
    end)
  end
end
