defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.{
    AllocationSequence,
    CashAllocation,
    CashPaymentDisposition,
    CashPaymentSettlement,
    CreditApplication,
    Group,
    PartnerOperation
  }

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_applications) do
      add :allocation_order, :integer
    end

    alter table(:cash_payment_dispositions) do
      add :has_transferred_funding, :boolean, null: false, default: false
    end

    create table(:allocation_sequences) do
    end

    create table(:cash_payment_settlements) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payment_settlements, [:payment_operation_id, :group_id])
    create index(:cash_payment_settlements, [:group_id])

    flush()
    backfill_allocation_orders()
    backfill_payment_settlements()
  end

  def down do
    drop index(:cash_payment_settlements, [:group_id])
    drop unique_index(:cash_payment_settlements, [:payment_operation_id, :group_id])
    drop table(:cash_payment_settlements)
    drop table(:allocation_sequences)

    alter table(:cash_payment_dispositions) do
      remove :has_transferred_funding
    end

    alter table(:credit_applications) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end

  defp backfill_allocation_orders do
    repo = repo()

    operation_orders =
      repo.all(
        from(operation in PartnerOperation, select: {operation.operation_id, operation.id})
      )
      |> Map.new()

    credit_operation_orders = credit_application_operation_orders(repo)

    cash_allocations =
      repo.all(from(allocation in CashAllocation))
      |> Enum.map(fn allocation ->
        allocation_entry(
          allocation,
          Map.get(operation_orders, allocation.payment_operation_id),
          :cash
        )
      end)

    credit_applications =
      repo.all(from(application in CreditApplication))
      |> Enum.map(fn application ->
        allocation_entry(
          application,
          Map.get(credit_operation_orders, application.id),
          :credit
        )
      end)

    (cash_allocations ++ credit_applications)
    |> Enum.sort_by(fn {rank, fallback_kind, id, _kind, _allocation} ->
      {rank, fallback_kind, id}
    end)
    |> Enum.each(fn
      {_rank, _fallback_kind, _id, :cash, allocation} ->
        sequence = repo.insert!(%AllocationSequence{})
        repo.update!(CashAllocation.changeset(allocation, %{allocation_order: sequence.id}))

      {_rank, _fallback_kind, _id, :credit, application} ->
        sequence = repo.insert!(%AllocationSequence{})
        repo.update!(CreditApplication.changeset(application, %{allocation_order: sequence.id}))
    end)
  end

  defp allocation_entry(allocation, operation_order, kind) do
    # Pre-durable funding has no operation identity. Request 04 defines it as a senior block,
    # with cash before credit; durable funding follows its recorded commit order.
    case operation_order do
      order when is_integer(order) -> {order, 0, allocation.id, kind, allocation}
      _ -> {0, if(kind == :cash, do: 0, else: 1), allocation.id, kind, allocation}
    end
  end

  defp credit_application_operation_orders(repo) do
    group_ids_by_partner_id =
      repo.all(from(group in Group, select: {group.group_id, group.id}))
      |> Map.new()

    applications_by_group =
      repo.all(from(application in CreditApplication, order_by: application.id))
      |> Enum.group_by(& &1.group_id)

    operations_by_group =
      repo.all(
        from(operation in PartnerOperation,
          where: operation.operation_type == "apply_hotel_credit",
          order_by: operation.id
        )
      )
      |> Enum.filter(&(&1.result["status"] == "applied"))
      |> Enum.group_by(&Map.get(group_ids_by_partner_id, &1.result["group_id"]))

    applications_by_group
    |> Enum.reduce(%{}, fn {group_id, applications}, orders ->
      operations = Map.get(operations_by_group, group_id, [])

      if Enum.sum_by(applications, & &1.amount_cents) ==
           Enum.sum_by(operations, & &1.result["amount_cents"]) do
        Map.merge(orders, assign_credit_application_operation_orders(applications, operations))
      else
        orders
      end
    end)
  end

  defp assign_credit_application_operation_orders(applications, operations) do
    case Enum.reduce_while(operations, {applications, %{}}, fn operation, {remaining, orders} ->
           case take_credit_applications(
                  remaining,
                  operation.result["amount_cents"],
                  operation.id,
                  orders
                ) do
             {:ok, next_remaining, next_orders} ->
               {:cont, {next_remaining, next_orders}}

             :error ->
               {:halt, :error}
           end
         end) do
      {[], orders} -> orders
      _ -> %{}
    end
  end

  defp take_credit_applications(applications, 0, _operation_id, orders),
    do: {:ok, applications, orders}

  defp take_credit_applications([], _amount, _operation_id, _orders), do: :error

  defp take_credit_applications([application | rest], amount, operation_id, orders) do
    if application.amount_cents <= amount do
      take_credit_applications(
        rest,
        amount - application.amount_cents,
        operation_id,
        Map.put(orders, application.id, operation_id)
      )
    else
      :error
    end
  end

  defp backfill_payment_settlements do
    repo = repo()

    repo.all(CashPaymentDisposition)
    |> Enum.each(fn disposition ->
      if disposition.refunded_cents > 0 or disposition.retained_cents > 0 or
           disposition.converted_to_credit_cents > 0 do
        repo.insert!(
          CashPaymentSettlement.changeset(%CashPaymentSettlement{}, %{
            group_id: disposition.group_id,
            payment_operation_id: disposition.payment_operation_id,
            refunded_cents: disposition.refunded_cents,
            retained_cents: disposition.retained_cents,
            converted_to_credit_cents: disposition.converted_to_credit_cents
          })
        )
      end
    end)
  end
end
