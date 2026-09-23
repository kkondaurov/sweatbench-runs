defmodule GroupStay.Payments do
  @moduledoc """
  Cash payments identified by their durable operation records, and what has become of their cash.

  A payment's cash is tracked through its `GroupStay.Groups.CashAllocation`s. Funding received
  before durable operation records has no payment identifier and cannot be addressed here.
  Changes are made through `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.{Credits, Deposits, OperationRecords}
  alias GroupStay.Groups.{CashAllocation, Group}
  alias GroupStay.OperationRecords.OperationRecord
  alias GroupStay.Repo

  @doc """
  The applied cash payment remembered as `payment_operation_id`. Returns `{:error, :not_found}`
  without a durable record and `{:error, :not_payment}` for any other remembered operation.
  """
  def fetch(payment_operation_id) when is_binary(payment_operation_id) do
    case OperationRecords.get(payment_operation_id) do
      nil ->
        {:error, :not_found}

      %OperationRecord{type: "record_cash_payment", status: "applied"} = record ->
        result = OperationRecords.result(record)

        {:ok,
         %{
           payment_operation_id: payment_operation_id,
           group_id: result["group_id"],
           recorded_cents: result["amount_cents"]
         }}

      %OperationRecord{} ->
        {:error, :not_payment}
    end
  end

  @doc "The current disposition of a payment's cash, in cents by allocation status."
  def dispositions(payment_operation_id) do
    totals =
      from(a in CashAllocation,
        where: a.payment_operation_id == ^payment_operation_id,
        group_by: a.status,
        select: {a.status, sum(a.amount_cents)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(CashAllocation.statuses(), &{&1, Map.get(totals, &1, 0)})
  end

  @doc """
  A reconciliation statement for one payment. Once any of the payment's cash has been transferred
  between groups, the statement also breaks its held cash down by the group holding it.
  """
  def statement(payment_operation_id) do
    with {:ok, payment} <- fetch(payment_operation_id) do
      cash = dispositions(payment_operation_id)

      {:ok,
       payment_operation_id
       |> held_by_group()
       |> Map.merge(%{
         payment_operation_id: payment.payment_operation_id,
         original_group_id: payment.group_id,
         recorded_cents: payment.recorded_cents,
         held_cents: cash["held"],
         refunded_cents: cash["refunded"],
         retained_cents: cash["retained"],
         converted_to_credit_cents: cash["converted"],
         reduced_cents: cash["reduced"],
         charged_back_cents: cash["charged_back"]
       })}
    end
  end

  # `%{held_by_group: [...]}` for a payment that has taken part in a transfer, ordered by
  # `group_id` and omitting groups holding none of its cash; otherwise `%{}`.
  defp held_by_group(payment_operation_id) do
    transferred? =
      Repo.exists?(
        from a in CashAllocation,
          where:
            a.payment_operation_id == ^payment_operation_id and
              not is_nil(a.transfer_operation_id)
      )

    if transferred? do
      held =
        from(a in CashAllocation,
          join: g in Group,
          on: g.id == a.group_ref,
          where: a.payment_operation_id == ^payment_operation_id and a.status == "held",
          group_by: g.group_id,
          having: sum(a.amount_cents) > 0,
          select: {g.group_id, sum(a.amount_cents)}
        )
        |> Repo.all()
        |> Enum.sort()

      %{
        held_by_group:
          for({group_id, cents} <- held, do: %{group_id: group_id, amount_cents: cents})
      }
    else
      %{}
    end
  end

  @doc """
  The credit entitlement each payment contributed to the lot `lot_ref`, as
  `{payment_operation_id, cents}` in funding order with the unattributed block (`nil`) first.

  A payment's entitlement is the bonus-inclusive value of the cash converted into the lot through
  that payment, minus the value through the preceding payment, so the entitlements sum exactly to
  the issued lot.
  """
  def lot_entitlements(lot_ref) do
    from(a in CashAllocation,
      where: a.lot_ref == ^lot_ref,
      group_by: a.payment_operation_id,
      select: {a.payment_operation_id, sum(a.amount_cents), {min(a.allocation_seq), min(a.id)}}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {payment, _cash, first} -> {payment != nil, first} end)
    |> Enum.map_reduce({0, 0}, fn {payment, cash, _first}, {converted, value} ->
      converted = converted + cash
      through = converted + Deposits.percentage_cents(converted, Credits.bonus_percent())
      {{payment, through - value}, {converted, through}}
    end)
    |> elem(0)
  end
end
