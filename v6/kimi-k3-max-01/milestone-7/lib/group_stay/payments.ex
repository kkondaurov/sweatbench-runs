defmodule GroupStay.Payments do
  @moduledoc """
  The payment context: the current disposition of cash recorded by durable
  cash payments, and the payment statement read model.

  Every applied payment starts fully `held`. Settlement, reductions, and
  chargebacks move amounts between dispositions without ever rewriting the
  payment's stored result; the dispositions of a payment always sum to its
  recorded amount. Cash from before durable operation records has no payment
  identity and never appears here.
  """

  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Operations
  alias GroupStay.Operations.Record
  alias GroupStay.Payments.Disposition
  alias GroupStay.Payments.Settlement
  alias GroupStay.Repo

  @settled_kinds ~w(refunded retained converted_to_credit)

  @doc """
  Whether a durable operation record is an applied cash payment and can
  therefore be reconciled, reduced, or charged back.
  """
  def applied_cash_payment?(%Record{} = record) do
    record.type == "record_cash_payment" and
      Operations.stored_result(record)["status"] == "applied"
  end

  @doc """
  The group addressed by a payment record: the original payment's group.
  """
  def payment_group(%Record{} = record) do
    record.payload
    |> Jason.decode!()
    |> Map.get("group_id")
    |> Groups.get_group()
  end

  @doc """
  Records a freshly applied cash payment as fully held.
  """
  def record_payment!(payment_operation_id, amount_cents) do
    %Disposition{}
    |> Disposition.changeset(%{
      payment_operation_id: payment_operation_id,
      kind: "held",
      amount_cents: amount_cents
    })
    |> Repo.insert!()
  end

  @doc """
  The payment's current dispositions as a `%{kind => amount_cents}` map.
  """
  def dispositions(payment_operation_id) do
    Disposition
    |> where(payment_operation_id: ^payment_operation_id)
    |> Repo.all()
    |> Map.new(fn disposition -> {disposition.kind, disposition.amount_cents} end)
  end

  @doc """
  The payment's currently held cash.
  """
  def held_cents(payment_operation_id) do
    payment_operation_id
    |> dispositions()
    |> Map.get("held", 0)
  end

  @doc """
  Moves `amount_cents` of the payment's cash from one disposition kind to
  another.
  """
  def move!(payment_operation_id, from_kind, to_kind, amount_cents) when amount_cents > 0 do
    from = get_disposition!(payment_operation_id, from_kind)

    if from.amount_cents < amount_cents do
      raise "cannot move #{amount_cents} from #{from_kind}: only #{from.amount_cents}"
    end

    {:ok, _from} =
      from
      |> Disposition.changeset(%{amount_cents: from.amount_cents - amount_cents})
      |> Repo.update()

    case get_disposition(payment_operation_id, to_kind) do
      nil ->
        %Disposition{}
        |> Disposition.changeset(%{
          payment_operation_id: payment_operation_id,
          kind: to_kind,
          amount_cents: amount_cents
        })
        |> Repo.insert!()

      to ->
        {:ok, _to} =
          to
          |> Disposition.changeset(%{amount_cents: to.amount_cents + amount_cents})
          |> Repo.update()
    end

    :ok
  end

  def move!(_payment_operation_id, _from_kind, _to_kind, 0), do: :ok

  @doc """
  Moves the held cash of the given cash allocations (already in allocation
  order) to a settled disposition kind. Returns the funding list of
  `{payment_operation_id, amount_cents}` pairs in funding order, with the
  unattributed senior block (`nil`) first; the senior block has no
  disposition to move.
  """
  def settle_allocations!(allocations, to_kind) do
    funding = funding_order(allocations)

    for {payer, amount} <- funding, not is_nil(payer) do
      move!(payer, "held", to_kind, amount)
    end

    funding
  end

  @doc """
  Records which group held the settled cash of the given allocations, so a
  later chargeback can reclassify it against the property where it settled.
  """
  def record_settlements!(allocations, to_kind) when to_kind in @settled_kinds do
    allocations
    |> Enum.filter(&(&1.kind == "cash" and not is_nil(&1.payment_operation_id)))
    |> Enum.group_by(&{&1.payment_operation_id, &1.group_id}, & &1.amount_cents)
    |> Enum.each(fn {{payer, group_id}, amounts} ->
      amount = Enum.sum(amounts)

      case settlement(payer, group_id, to_kind) do
        nil ->
          %Settlement{}
          |> Settlement.changeset(%{
            payment_operation_id: payer,
            group_id: group_id,
            kind: to_kind,
            amount_cents: amount
          })
          |> Repo.insert!()

        existing ->
          {:ok, _} =
            existing
            |> Settlement.changeset(%{amount_cents: existing.amount_cents + amount})
            |> Repo.update()
      end
    end)

    :ok
  end

  @doc """
  The settled-group attributions of the payment's settled cash in the given
  kind: `{group_db_id, amount_cents}` pairs.
  """
  def settled_attributions(payment_operation_id, kind) do
    Settlement
    |> where(payment_operation_id: ^payment_operation_id, kind: ^kind)
    |> select([settlement], {settlement.group_id, settlement.amount_cents})
    |> Repo.all()
  end

  @doc """
  Clears the payment's settled-group attributions of a kind after a
  chargeback consumed them.
  """
  def clear_settlements!(payment_operation_id, kind) do
    Settlement
    |> where(payment_operation_id: ^payment_operation_id, kind: ^kind)
    |> Repo.delete_all()

    :ok
  end

  defp settlement(payer, group_id, kind) do
    Settlement
    |> where(payment_operation_id: ^payer, group_id: ^group_id, kind: ^kind)
    |> Repo.one()
  end

  @doc """
  The cash funding of the given allocations as `{payment_operation_id,
  amount_cents}` pairs in funding order: aggregated per payment in
  first-occurrence order, with the unattributed senior block first.
  """
  def funding_order(allocations) do
    aggregated =
      allocations
      |> Enum.filter(&(&1.kind == "cash"))
      |> Enum.reduce([], fn allocation, acc ->
        case List.keyfind(acc, allocation.payment_operation_id, 0) do
          nil ->
            acc ++ [{allocation.payment_operation_id, allocation.amount_cents}]

          {payer, amount} ->
            List.keyreplace(acc, payer, 0, {payer, amount + allocation.amount_cents})
        end
      end)

    {senior, rest} = Enum.split_with(aggregated, fn {payer, _amount} -> is_nil(payer) end)
    senior ++ rest
  end

  @doc """
  Records that cash from the given payments has participated in a deposit
  transfer.
  """
  def mark_transferred!(payment_operation_ids) do
    Disposition
    |> where([disposition], disposition.payment_operation_id in ^payment_operation_ids)
    |> Repo.update_all(set: [participated_in_transfer: true])

    :ok
  end

  @doc """
  Whether any funding from the payment has participated in a deposit
  transfer.
  """
  def participated_in_transfer?(payment_operation_id) do
    Disposition
    |> where(payment_operation_id: ^payment_operation_id, participated_in_transfer: true)
    |> Repo.exists?()
  end

  @doc """
  The payment's held cash grouped by the group currently holding it,
  ordered by `group_id`. Groups with no held cash are omitted.
  """
  def held_by_group(payment_operation_id) do
    Allocation
    |> where(kind: "cash", payment_operation_id: ^payment_operation_id)
    |> join(:inner, [allocation], group in Group, on: group.id == allocation.group_id)
    |> group_by([_allocation, group], group.group_id)
    |> select([allocation, group], {group.group_id, sum(allocation.amount_cents)})
    |> order_by([_allocation, group], asc: group.group_id)
    |> Repo.all()
    |> Enum.filter(fn {_group_id, amount} -> amount > 0 end)
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount} end)
  end

  @doc """
  The payment statement returned by the read endpoint: every amount is the
  current disposition of cash from the payment, and the disposition fields
  sum exactly to `recorded_cents`. Once any funding from the payment has
  participated in a transfer, the statement adds `held_by_group`.
  """
  def statement_payload(%Record{} = record) do
    result = Operations.stored_result(record)
    dispositions = dispositions(record.operation_id)

    payload = %{
      payment_operation_id: record.operation_id,
      original_group_id: result["group_id"],
      recorded_cents: result["amount_cents"],
      held_cents: Map.get(dispositions, "held", 0),
      refunded_cents: Map.get(dispositions, "refunded", 0),
      retained_cents: Map.get(dispositions, "retained", 0),
      converted_to_credit_cents: Map.get(dispositions, "converted_to_credit", 0),
      reduced_cents: Map.get(dispositions, "reduced", 0),
      charged_back_cents: Map.get(dispositions, "charged_back", 0)
    }

    if participated_in_transfer?(record.operation_id) do
      Map.put(payload, :held_by_group, held_by_group(record.operation_id))
    else
      payload
    end
  end

  defp get_disposition!(payment_operation_id, kind) do
    Disposition
    |> where(payment_operation_id: ^payment_operation_id, kind: ^kind)
    |> Repo.one!()
  end

  defp get_disposition(payment_operation_id, kind) do
    Disposition
    |> where(payment_operation_id: ^payment_operation_id, kind: ^kind)
    |> Repo.one()
  end
end
