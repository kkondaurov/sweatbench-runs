defmodule GroupStay.Payments do
  @moduledoc """
  Reconciliation of a single recorded cash payment.

  A payment's recorded cash is partitioned into its current dispositions: held
  on active rooms, refunded, retained, converted to hotel credit, reduced by a
  provider correction, or charged back. Reading a statement never changes
  state.
  """

  import Ecto.Query

  alias GroupStay.Funding.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @doc """
  Returns the current disposition of one durably recorded, applied cash
  payment, or an error tuple.

  `:operation_not_found` when no durable operation record exists;
  `:payment_not_reconcilable` when the record exists but is not an applied cash
  payment.
  """
  def statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        case applied_cash_payment_group(record) do
          {:ok, group_id} -> {:ok, build_statement(payment_operation_id, group_id)}
          :error -> {:error, :payment_not_reconcilable}
        end
    end
  end

  def statement(_other), do: {:error, :operation_not_found}

  defp applied_cash_payment_group(record) do
    with "record_cash_payment" <- record.type,
         {:ok, result} <- Jason.decode(record.result),
         %{"status" => "applied", "group_id" => group_id} <- result,
         true <- is_binary(group_id) do
      {:ok, group_id}
    else
      _other -> :error
    end
  end

  defp build_statement(payment_operation_id, group_id) do
    allocations =
      Repo.all(
        from a in Allocation,
          where: a.kind == "cash" and a.payment_operation_id == ^payment_operation_id
      )

    held = sum_disposition(allocations, "held")
    refunded = sum_disposition(allocations, "refunded")
    retained = sum_disposition(allocations, "retained")
    converted = sum_disposition(allocations, "converted")
    reduced = sum_disposition(allocations, "reduced")
    charged_back = sum_disposition(allocations, "charged_back")

    statement = %{
      payment_operation_id: payment_operation_id,
      original_group_id: group_id,
      recorded_cents: held + refunded + retained + converted + reduced + charged_back,
      held_cents: held,
      refunded_cents: refunded,
      retained_cents: retained,
      converted_to_credit_cents: converted,
      reduced_cents: reduced,
      charged_back_cents: charged_back
    }

    # Once any funding from the payment has participated in a transfer, the
    # statement reports which groups currently hold its cash. Payments that
    # have never participated in a transfer keep the earlier shape.
    if Enum.any?(allocations, & &1.transferred) do
      Map.put(statement, :held_by_group, held_by_group(allocations))
    else
      statement
    end
  end

  defp held_by_group(allocations) do
    by_group =
      allocations
      |> Enum.filter(&(&1.disposition == "held"))
      |> Enum.group_by(& &1.group_id, & &1.amount_cents)

    if by_group == %{} do
      []
    else
      internal_ids = Map.keys(by_group)

      partner_ids =
        Repo.all(from g in Group, where: g.id in ^internal_ids, select: {g.id, g.group_id})
        |> Map.new()

      by_group
      |> Enum.map(fn {internal_id, amounts} ->
        %{group_id: Map.fetch!(partner_ids, internal_id), amount_cents: Enum.sum(amounts)}
      end)
      |> Enum.sort_by(& &1.group_id)
    end
  end

  defp sum_disposition(allocations, disposition) do
    allocations
    |> Enum.filter(&(&1.disposition == disposition))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end
end
