defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles recorded cash and changes its dispositions without rewriting receipts.

  All writes share the partner operation's transaction. Payment identity comes
  from an applied cash operation's retained type, never from a caller's group ID
  or the shape of a result shared with credit applications.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.{Accounting, HotelCredit, Repo}
  alias GroupStay.Accounting.{CashPayment, CashSettlement}
  alias GroupStay.Finance.Journal
  alias GroupStay.Operations.Operation

  def statement(operation_id) do
    {:ok, result} = Repo.transaction(fn -> read_statement(operation_id) end)
    result
  end

  defp read_statement(operation_id) do
    with {:ok, payment} <- fetch(operation_id, :payment_not_reconcilable) do
      statement =
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
        |> Map.put(:held_cents, CashPayment.held_cents(payment))

      if payment.transferred do
        {:ok, Map.put(statement, :held_by_group, Accounting.held_cash_by_group(payment.id))}
      else
        {:ok, statement}
      end
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

  def record(group, operation, journal) do
    payment =
      Repo.insert!(%CashPayment{
        group_id: group.group_id,
        payment_operation_id: operation["operation_id"],
        recorded_cents: operation["amount_cents"]
      })

    Accounting.fund(group.group_id, payment.recorded_cents, cash_payment_id: payment.id)
    Journal.cash(journal, group.property_id, :received_cents, payment.recorded_cents)
  end

  @doc "Settles selected cash allocations and returns contributions in funding order."
  def settle(group_id, allocations, disposition, journal) do
    # A transfer creates new allocations in draw order. Use the first selected
    # allocation of each payment to retain that funding order for lot entitlement.
    contributions =
      allocations
      |> Enum.reject(&is_nil(&1.cash_payment_id))
      |> Enum.group_by(& &1.cash_payment_id)
      |> Enum.sort_by(fn {_id, allocations} -> Enum.min_by(allocations, & &1.id).id end)
      |> Enum.map(fn {id, allocations} ->
        {id, Enum.sum(Enum.map(allocations, & &1.amount_cents))}
      end)

    for {id, amount} <- contributions do
      payment = Repo.get!(CashPayment, id)
      change(payment, %{disposition => Map.fetch!(payment, disposition) + amount})

      settlement =
        Repo.get_by(CashSettlement, cash_payment_id: id, group_id: group_id) ||
          %CashSettlement{cash_payment_id: id, group_id: group_id}

      settlement
      |> Changeset.change(%{disposition => Map.fetch!(settlement, disposition) + amount})
      |> Repo.insert_or_update!()

      Journal.cash_at_group(journal, group_id, disposition, amount)
    end

    contributions
  end

  def reduce(payment, amount, journal) do
    held = CashPayment.held_cents(payment)

    cond do
      held == 0 ->
        {:error, :payment_not_reducible}

      not is_integer(amount) or amount <= 0 ->
        {:error, :invalid_amount}

      amount > held ->
        {:error, :reduction_exceeds_held_cash}

      true ->
        changed_groups = remove_held_cash(payment.id, amount, journal, :reduced_cents)
        change(payment, %{reduced_cents: payment.reduced_cents + amount})
        {:ok, changed_groups}
    end
  end

  def charge_back(payment, journal) do
    amount = payment.recorded_cents - payment.reduced_cents

    if amount == 0 or payment.charged_back_cents > 0 do
      {:error, :payment_not_chargeable}
    else
      changed_groups =
        remove_held_cash(
          payment.id,
          CashPayment.held_cents(payment),
          journal,
          :charged_back_cents
        )

      settlements =
        from settlement in CashSettlement, where: settlement.cash_payment_id == ^payment.id

      settled = Repo.all(settlements)

      for settlement <- settled,
          disposition <- [:refunded_cents, :retained_cents, :converted_to_credit_cents] do
        amount = Map.fetch!(settlement, disposition)
        Journal.cash_at_group(journal, settlement.group_id, disposition, -amount)
        Journal.cash_at_group(journal, settlement.group_id, :charged_back_cents, amount)
      end

      settled_groups = Enum.map(settled, & &1.group_id)
      Repo.delete_all(settlements)
      HotelCredit.revoke(payment.id, journal)

      change(payment, %{
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: amount
      })

      {:ok, amount, Enum.uniq(changed_groups ++ settled_groups)}
    end
  end

  defp remove_held_cash(payment_id, amount, journal, classification) do
    payment_id
    |> Accounting.remove_cash(amount)
    |> Enum.map(fn {_allocation, group_id, removed} ->
      Journal.cash_at_group(journal, group_id, classification, removed)
      group_id
    end)
    |> Enum.uniq()
  end

  @doc "Current cash settlements at a group, irrespective of the payments' original groups."
  def settled_totals(group_id) do
    from(settlement in CashSettlement, where: settlement.group_id == ^group_id)
    |> Repo.all()
    |> Enum.reduce(
      %{refunded_cents: 0, retained_cents: 0, cash_converted_to_credit_cents: 0},
      fn settlement, totals ->
        %{
          refunded_cents: totals.refunded_cents + settlement.refunded_cents,
          retained_cents: totals.retained_cents + settlement.retained_cents,
          cash_converted_to_credit_cents:
            totals.cash_converted_to_credit_cents + settlement.converted_to_credit_cents
        }
      end
    )
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
