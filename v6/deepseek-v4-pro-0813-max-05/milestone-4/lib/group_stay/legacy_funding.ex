defmodule GroupStay.LegacyFunding do
  @moduledoc """
  Brings pre-durable funding forward as one unattributed senior block per
  group.

  When this release was deployed, some active groups held funding from
  before durable operation records existed. That funding has no operation
  identity: cash cannot be reduced or charged back and credit cannot be
  traced to a payment. The legacy cash is allocated as a single aggregate
  event, followed by its hotel-credit applications in consumption order,
  and only then the funding represented by durable operation records in
  commit order. Creating the allocations never changes aggregate cash,
  credit, or liability balances.

  Forwarding runs once per group. The marker row and the allocation rows
  commit together, so a forward is either fully visible or not at all.
  """

  alias GroupStay.{
    CreditApplication,
    DurableOperation,
    LegacyForwarding,
    Payment,
    Repo,
    Room,
    RoomAccounting,
    RoomAllocation
  }

  import Ecto.Query

  @doc "Brings the group's legacy funding forward, at most once."
  def ensure_forwarded(group) do
    case Repo.transaction(fn -> forward_once(group) end) do
      {:ok, _result} -> :ok
      {:error, :already_forwarded} -> :ok
    end
  end

  defp forward_once(group) do
    if Repo.get_by(LegacyForwarding, group_id: group.id) do
      :ok
    else
      case Repo.insert(%LegacyForwarding{group_id: group.id}) do
        {:ok, _marker} ->
          forward_group(group)

        {:error, _changeset} ->
          Repo.rollback(:already_forwarded)
      end
    end
  end

  defp forward_group(group) do
    move_legacy_settlement(group)
    link_durable_payments(group)
    link_durable_credit(group)

    case group.status do
      "active" ->
        allocate_events(group)

      # A group that was already cancelled under an earlier release had all
      # of its rooms settled; rooms gained statuses only now.
      _ ->
        Repo.update_all(
          from(r in Room, where: r.group_id == ^group.id and r.status == "active"),
          set: [status: "cancelled"]
        )
    end

    :ok
  end

  ## Legacy settlement rows (payments created with kind refund/retained/
  ## converted before disposition columns existed) fold into disposition
  ## columns. They are distributed over the group's payments in funding
  ## order so each payment's dispositions keep summing to its recorded
  ## amount.

  defp move_legacy_settlement(group) do
    rows =
      Repo.all(
        from(p in Payment,
          where: p.group_id == ^group.id and p.kind != "payment"
        )
      )

    if rows != [] do
      kind_pools =
        Enum.reduce(rows, %{"refund" => 0, "retained" => 0, "converted" => 0}, fn row, pools ->
          Map.update!(pools, row.kind, &(&1 + row.amount_cents))
        end)

      {_pools, settlements} =
        group
        |> payment_rows_in_order()
        |> Enum.reduce({kind_pools, []}, fn payment, {pools, acc} ->
          assigned = min(pools_total(pools), payment.amount_cents)
          {pools, splits} = split_dispositions(pools, assigned)
          {pools, [{payment, splits} | acc]}
        end)

      settlements
      |> Enum.reverse()
      |> Enum.each(fn {payment, splits} ->
        Repo.update_all(
          from(p in Payment, where: p.id == ^payment.id),
          set: splits
        )
      end)

      Repo.delete_all(from(p in Payment, where: p.group_id == ^group.id and p.kind != "payment"))
    end
  end

  defp pools_total(pools), do: pools["refund"] + pools["retained"] + pools["converted"]

  defp split_dispositions(pools, assigned) do
    {refund, pools} = take_from_pool(pools, "refund", assigned)
    {retained, pools} = take_from_pool(pools, "retained", assigned - refund)
    {converted, pools} = take_from_pool(pools, "converted", assigned - refund - retained)

    {pools,
     [
       refunded_cents: refund,
       retained_cents: retained,
       converted_cents: converted
     ]}
  end

  defp take_from_pool(pools, kind, wanted) do
    taken = min(Map.fetch!(pools, kind), wanted)
    {taken, Map.update!(pools, kind, &(&1 - taken))}
  end

  defp payment_rows_in_order(group) do
    Repo.all(
      from(p in Payment,
        where: p.group_id == ^group.id and p.kind == "payment",
        order_by: [asc: p.inserted_at, asc: p.id]
      )
    )
  end

  defp legacy_payment_rows(group) do
    Repo.all(
      from(p in Payment,
        where: p.group_id == ^group.id and p.kind == "payment" and is_nil(p.operation_id),
        order_by: [asc: p.inserted_at, asc: p.id]
      )
    )
  end

  defp legacy_application_rows(group) do
    Repo.all(
      from(a in CreditApplication,
        where: a.group_id == ^group.id and is_nil(a.operation_id),
        order_by: [asc: a.inserted_at, asc: a.id]
      )
    )
  end

  ## Match existing payment and application rows to their durable
  ## operations. Matching is greedy and chronological; rows that no durable
  ## operation claims stay in the legacy block.

  defp link_durable_payments(group) do
    rows =
      Repo.all(
        from(p in Payment,
          where: p.group_id == ^group.id and p.kind == "payment",
          order_by: [asc: p.inserted_at, asc: p.id]
        )
      )

    group
    |> durable_funding_ops("record_cash_payment")
    |> Enum.reduce(rows, fn {payload, _result}, acc ->
      case Enum.find_index(acc, &(&1.amount_cents == payload["amount_cents"])) do
        nil ->
          acc

        index ->
          row = Enum.at(acc, index)

          Repo.update_all(
            from(p in Payment, where: p.id == ^row.id and is_nil(p.operation_id)),
            set: [operation_id: payload["operation_id"]]
          )

          List.delete_at(acc, index)
      end
    end)
  end

  defp link_durable_credit(group) do
    rows =
      Repo.all(
        from(a in CreditApplication,
          where: a.group_id == ^group.id,
          order_by: [asc: a.inserted_at, asc: a.id]
        )
      )

    group
    |> durable_funding_ops("apply_hotel_credit")
    |> Enum.reduce(rows, fn {payload, _result}, acc ->
      greedy_claim(acc, payload["amount_cents"], payload["operation_id"])
    end)
  end

  # One apply_hotel_credit operation may have produced several application
  # rows (one per consumed lot). Consecutive rows are claimed until they
  # sum to the operation's amount.
  defp greedy_claim(rows, target, operation_id) do
    rows
    |> Enum.reduce_while({[], 0}, fn row, {taken, sum} ->
      next = sum + row.amount_cents
      if next > target, do: {:halt, :overflow}, else: {:cont, {[row | taken], next}}
    end)
    |> case do
      {taken, ^target} ->
        taken = Enum.reverse(taken)
        ids = Enum.map(taken, & &1.id)

        Repo.update_all(
          from(a in CreditApplication, where: a.id in ^ids),
          set: [operation_id: operation_id]
        )

        Enum.drop(rows, length(taken))

      :overflow ->
        rows
    end
  end

  defp durable_funding_ops(group, op_type) do
    Repo.all(
      from(d in DurableOperation,
        where: d.op_type == ^op_type,
        order_by: [asc: d.id]
      )
    )
    |> Enum.map(fn durable ->
      {Jason.decode!(durable.payload_json), Jason.decode!(durable.result_json)}
    end)
    |> Enum.filter(fn {payload, result} ->
      payload["group_id"] == group.group_id and result["status"] == "applied"
    end)
  end

  ## Allocation events. The senior block comes first: aggregate legacy cash,
  ## then legacy credit in consumption order, then durable-recorded funding
  ## in commit order regardless of occurred_on. Only amounts that have not
  ## already been allocated are considered, which keeps the step idempotent.

  defp allocate_events(group) do
    events =
      legacy_cash_event(group) ++
        Enum.map(legacy_application_rows(group), &{:credit, &1, app_unallocated(&1)}) ++
        Enum.map(durable_payment_events(group), fn {payment, amount} ->
          {:cash, payment, amount}
        end) ++
        Enum.map(durable_credit_events(group), fn {app, amount} -> {:credit, app, amount} end)

    Enum.each(events, fn
      {_kind, _ref, amount} when amount <= 0 ->
        :ok

      {:cash, payment, amount} ->
        RoomAccounting.allocate_cash(group, payment, amount)

      {:credit, application, amount} ->
        RoomAccounting.allocate_credit(group, application, amount)
    end)
  end

  defp legacy_cash_event(group) do
    rows = legacy_payment_rows(group)

    if rows == [] do
      []
    else
      carrier = List.first(rows)
      ids = Enum.map(rows, & &1.id)
      total = Enum.reduce(rows, 0, fn row, sum -> row.amount_cents + sum end)

      allocated =
        Repo.aggregate(
          from(a in RoomAllocation, where: a.payment_id in ^ids),
          :sum,
          :amount_cents
        ) || 0

      [{:cash, carrier, max(total - allocated, 0)}]
    end
  end

  defp durable_payment_events(group) do
    group
    |> durable_funding_ops("record_cash_payment")
    |> Enum.flat_map(fn {payload, _result} ->
      case Repo.get_by(Payment, operation_id: payload["operation_id"]) do
        nil -> []
        payment -> [{payment, row_unallocated(payment)}]
      end
    end)
  end

  defp durable_credit_events(group) do
    group
    |> durable_funding_ops("apply_hotel_credit")
    |> Enum.flat_map(fn {payload, _result} ->
      payload["operation_id"]
      |> applications_for()
    end)
    |> Enum.map(&{&1, app_unallocated(&1)})
  end

  defp applications_for(operation_id) do
    Repo.all(
      from(a in CreditApplication,
        where: a.operation_id == ^operation_id,
        order_by: [asc: a.inserted_at, asc: a.id]
      )
    )
  end

  defp app_unallocated(app) do
    allocated =
      Repo.aggregate(
        from(a in RoomAllocation, where: a.credit_application_id == ^app.id),
        :sum,
        :amount_cents
      ) || 0

    max(app.amount_cents - allocated, 0)
  end

  defp row_unallocated(payment) do
    allocated =
      Repo.aggregate(
        from(a in RoomAllocation, where: a.payment_id == ^payment.id),
        :sum,
        :amount_cents
      ) || 0

    max(payment.amount_cents - allocated, 0)
  end
end
