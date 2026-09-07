defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles durably recorded cash payments and changes their current dispositions.

  Corrections never rewrite the payment's submission, original result, or cash
  entry. Cash allocations partition its recorded principal, including settled
  history. All writes run within the partner operation's transaction.
  """

  import Ecto.Query

  alias GroupStay.{Credits, Repo}
  alias GroupStay.Finance.CashAllocation
  alias GroupStay.Operations.Record

  @dispositions [:held, :refunded, :retained, :converted_to_credit, :reduced, :charged_back]

  @doc "Looks up an applied cash payment using its retained type and result."
  def fetch(payment_operation_id, invalid_code) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{operation_type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        {:ok, record}

      _ ->
        {:error, invalid_code}
    end
  end

  @doc "Returns a consistent, read-only statement of this payment's current cash."
  def statement(payment_operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        with {:ok, payment} <- fetch(payment_operation_id, "payment_not_reconcilable") do
          amounts = dispositions(payment)

          {:ok,
           %{
             payment_operation_id: payment.operation_id,
             original_group_id: payment.result["group_id"],
             recorded_cents: payment.result["amount_cents"],
             held_cents: amounts.held,
             refunded_cents: amounts.refunded,
             retained_cents: amounts.retained,
             converted_to_credit_cents: amounts.converted_to_credit,
             reduced_cents: amounts.reduced,
             charged_back_cents: amounts.charged_back
           }}
        end
      end)

    result
  end

  def dispositions(payment) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment.operation_id
    )
    |> Enum.reduce(Map.new(@dispositions, &{&1, 0}), fn allocation, totals ->
      Map.update!(totals, allocation.disposition, &(&1 + allocation.amount_cents))
    end)
  end

  def held_on_rooms(rooms) do
    ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from allocation in CashAllocation,
        where: allocation.room_id in ^ids and allocation.disposition == :held,
        order_by: allocation.id
    )
  end

  def settle!(allocations, disposition, lot_id \\ nil) do
    Enum.each(allocations, fn allocation ->
      allocation
      |> Ecto.Changeset.change(disposition: disposition, credit_lot_id: lot_id)
      |> Repo.update!()
    end)
  end

  @doc "Removes held principal from the last-filled room portions first."
  def reduce!(payment, amount) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.payment_operation_id == ^payment.operation_id and
              allocation.disposition == :held,
          order_by: [desc: allocation.id]
      )

    0 =
      Enum.reduce(allocations, amount, fn allocation, remaining ->
        removed = min(allocation.amount_cents, remaining)
        if removed > 0, do: reclassify_portion!(allocation, removed, :reduced)
        remaining - removed
      end)

    :ok
  end

  @doc "Reclassifies all unreduced principal and revokes its credit entitlements."
  def charge_back!(payment) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.payment_operation_id == ^payment.operation_id and
              allocation.disposition not in [:reduced, :charged_back],
          order_by: [desc: allocation.id]
      )

    Enum.each(allocations, fn allocation ->
      allocation |> Ecto.Changeset.change(disposition: :charged_back) |> Repo.update!()
    end)

    Credits.revoke_entitlements!(payment.operation_id)
    Enum.sum(Enum.map(allocations, & &1.amount_cents))
  end

  defp reclassify_portion!(allocation, amount, disposition)
       when amount == allocation.amount_cents do
    allocation |> Ecto.Changeset.change(disposition: disposition) |> Repo.update!()
  end

  defp reclassify_portion!(allocation, amount, disposition) do
    allocation
    |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
    |> Repo.update!()

    %CashAllocation{
      group_id: allocation.group_id,
      room_id: allocation.room_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: amount,
      disposition: disposition
    }
    |> Repo.insert!()
  end
end
