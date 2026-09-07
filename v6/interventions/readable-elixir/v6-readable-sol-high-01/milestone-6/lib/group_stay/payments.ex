defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles durable cash payments and their current accounting disposition.

  The immutable partner-operation record proves what was originally accepted;
  `CashPayment` records how those cents are classified today.
  """

  import Ecto.Query

  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Payments.{CashAllocation, CashPayment, CashPaymentGroupDisposition}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, RoomAccounting}

  @disposition_fields %{
    refunded: :refunded_cents,
    retained: :retained_cents,
    converted: :converted_to_credit_cents
  }

  @group_disposition_fields %{
    refunded: :refunded_cents,
    retained: :retained_cents,
    converted: :converted_to_credit_cents
  }

  @doc "Records and allocates a newly applied cash payment."
  def record!(%Group{} = group, operation_id, amount_cents) do
    funding_order = RoomAccounting.next_funding_order()

    payment =
      %CashPayment{}
      |> CashPayment.changeset(%{
        payment_operation_id: operation_id,
        group_record_id: group.id,
        funding_order: funding_order,
        recorded_cents: amount_cents,
        held_cents: amount_cents,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0,
        transfer_participated: false
      })
      |> Repo.insert!()

    {payment, RoomAccounting.allocate_cash(group, payment, amount_cents)}
  end

  @doc "Moves selected held allocations into a settlement classification."
  def settle_rooms!(rooms, disposition) when disposition in [:refunded, :retained, :converted] do
    allocations = RoomAccounting.take_room_cash_allocations(rooms)
    field = Map.fetch!(@disposition_fields, disposition)

    allocations
    |> Enum.reject(&is_nil(&1.cash_payment_id))
    |> Enum.group_by(& &1.cash_payment_id)
    |> Enum.each(fn {_payment_id, grouped} ->
      first = hd(grouped)
      amount = Enum.reduce(grouped, 0, &(&1.amount_cents + &2))
      payment = first.cash_payment

      update_payment!(
        payment,
        %{held_cents: payment.held_cents - amount}
        |> Map.put(field, Map.fetch!(payment, field) + amount)
      )

      record_group_disposition!(payment, first.group_record_id, disposition, amount)
    end)

    contributors =
      Enum.map(allocations, fn allocation ->
        %{
          payment_id: allocation.cash_payment_id,
          funding_order: allocation.allocation_order,
          amount_cents: allocation.amount_cents
        }
      end)

    %{
      amount_cents: Enum.reduce(contributors, 0, &(&1.amount_cents + &2)),
      contributors: contributors
    }
  end

  @doc "Returns a payment target, distinguishing a missing record from a wrong kind."
  def operation_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      %{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(CashPayment, payment_operation_id: operation_id) do
          nil -> raise "applied cash operation #{operation_id} has no payment accounting record"
          payment -> {:ok, Repo.preload(payment, :group)}
        end

      _record ->
        {:error, :not_payment}
    end
  end

  def operation_payment(_operation_id), do: {:error, :operation_not_found}

  @doc "Reduces held cash from the end of a payment's fill sequence."
  def reduce!(%CashPayment{} = payment, amount_cents) do
    groups = RoomAccounting.reduce_cash!(payment, amount_cents)

    payment =
      update_payment!(payment, %{
        held_cents: payment.held_cents - amount_cents,
        reduced_cents: payment.reduced_cents + amount_cents
      })

    {payment, groups}
  end

  @doc "Reclassifies every non-reduced cent of a payment as charged back."
  def charge_back!(%CashPayment{} = payment) do
    held_groups =
      if payment.held_cents > 0 do
        RoomAccounting.reduce_cash!(payment, payment.held_cents)
      else
        []
      end

    settled_groups = clear_group_dispositions!(payment)

    charged =
      payment.held_cents + payment.refunded_cents + payment.retained_cents +
        payment.converted_to_credit_cents

    payment =
      update_payment!(payment, %{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + charged
      })

    {payment, unique_groups(held_groups ++ settled_groups), charged}
  end

  @doc "Returns the exact public reconciliation statement for an applied payment."
  def fetch_statement(operation_id) do
    case operation_payment(operation_id) do
      {:ok, payment} -> {:ok, to_api(payment)}
      {:error, :operation_not_found} -> {:error, :operation_not_found}
      {:error, :not_payment} -> {:error, :payment_not_reconcilable}
    end
  end

  @doc "Cumulative cash removed through provider reductions."
  def reduced_total do
    Repo.aggregate(CashPayment, :sum, :reduced_cents) || 0
  end

  @doc "Cumulative cash reclassified through chargebacks."
  def charged_back_total do
    Repo.aggregate(CashPayment, :sum, :charged_back_cents) || 0
  end

  defp to_api(payment) do
    statement = %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.group.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.transfer_participated do
      Map.put(statement, :held_by_group, held_by_group(payment))
    else
      statement
    end
  end

  defp held_by_group(payment) do
    CashAllocation
    |> join(:inner, [allocation], group in Group, on: group.id == allocation.group_record_id)
    |> where([allocation], allocation.cash_payment_id == ^payment.id)
    |> group_by([_allocation, group], [group.group_id])
    |> order_by([_allocation, group], asc: group.group_id)
    |> select([allocation, group], %{
      group_id: group.group_id,
      amount_cents: sum(allocation.amount_cents)
    })
    |> Repo.all()
  end

  defp record_group_disposition!(payment, group_id, disposition, amount) do
    field = Map.fetch!(@group_disposition_fields, disposition)

    record =
      Repo.get_by(CashPaymentGroupDisposition,
        cash_payment_id: payment.id,
        group_record_id: group_id
      ) ||
        %CashPaymentGroupDisposition{
          cash_payment_id: payment.id,
          group_record_id: group_id,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0
        }

    record
    |> CashPaymentGroupDisposition.changeset(%{
      field => Map.fetch!(record, field) + amount
    })
    |> Repo.insert_or_update!()
  end

  defp clear_group_dispositions!(payment) do
    CashPaymentGroupDisposition
    |> where([disposition], disposition.cash_payment_id == ^payment.id)
    |> preload(:group)
    |> Repo.all()
    |> Enum.map(fn disposition ->
      group = disposition.group

      group =
        group
        |> Group.accounting_changeset(%{
          refunded_cents: group.refunded_cents - disposition.refunded_cents,
          retained_cents: group.retained_cents - disposition.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - disposition.converted_to_credit_cents
        })
        |> Repo.update!()

      Repo.delete!(disposition)
      group
    end)
  end

  defp unique_groups(groups), do: Enum.uniq_by(groups, & &1.id)

  defp update_payment!(payment, attrs) do
    payment |> CashPayment.changeset(attrs) |> Repo.update!()
  end
end
