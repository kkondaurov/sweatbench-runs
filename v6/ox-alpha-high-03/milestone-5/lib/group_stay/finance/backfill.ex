defmodule GroupStay.Finance.Backfill do
  @moduledoc """
  Brings funding that predates room allocations forward onto rooms.

  Run once by the room-accounting migration. For every group it rebuilds the
  recorded cash movements so payments made through durable operations are
  identified by their operation id, then allocates each active group's funding
  onto its rooms without changing any aggregate balance:

  1. the unattributed senior block: aggregate legacy cash first, then legacy
     hotel-credit applications in original consumption order;
  2. funding represented by durable operation records, classified by retained
     type and allocated in durable-record commit order.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Finance.Allocations
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  def backfill do
    Repo.all(from g in Group, preload: [:rooms])
    |> Enum.each(&backfill_group/1)
  end

  defp backfill_group(group) do
    payments = durable_payments(group.group_id)

    if payments != [] do
      rewrite_cash_movements(group, payments)
    end

    if group.status == "active" do
      Allocations.allocate(group.id, funding_units(group, payments))
    end
  end

  # Applied cash payments represented by durable records, in commit order.
  defp durable_payments(group_id) do
    from(r in OperationRecord,
      where: r.type == "record_cash_payment",
      order_by: [asc: r.id]
    )
    |> Repo.all()
    |> Enum.map(&{&1, Jason.decode!(&1.result)})
    |> Enum.filter(fn {_record, result} ->
      result["status"] == "applied" and result["group_id"] == group_id
    end)
    |> Enum.map(fn {record, result} ->
      %{
        operation_id: record.operation_id,
        amount_cents: result["amount_cents"],
        occurred_on: submitted_occurred_on(record)
      }
    end)
  end

  defp submitted_occurred_on(record) do
    case record.submission && Jason.decode(record.submission) do
      {:ok, %{"occurred_on" => value}} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _error -> nil
        end

      _other ->
        nil
    end
  end

  # Pre-release movements carry no operation identity. Rebuild them so each
  # durable payment keeps its own disposition trail while every aggregate cash
  # balance stays exactly the same.
  defp rewrite_cash_movements(group, payments) do
    rows = Repo.all(from m in CashMovement, where: m.group_id == ^group.id, order_by: [asc: m.id])
    recorded_total = rows |> Enum.map(& &1.amount_cents) |> Enum.sum()

    payments_total = payments |> Enum.map(& &1.amount_cents) |> Enum.sum()
    legacy_total = recorded_total - payments_total

    if legacy_total < 0 do
      raise("group #{group.group_id} records less cash than its durable payments")
    end

    kind = settlement_kind(group, rows)
    fallback_date = rows |> List.first() |> then(&(&1 && &1.occurred_on)) || Date.utc_today()

    Repo.delete_all(from m in CashMovement, where: m.group_id == ^group.id)

    if legacy_total > 0 do
      insert_movement(group.id, kind, legacy_total, nil, fallback_date)
    end

    Enum.each(payments, fn payment ->
      insert_movement(
        group.id,
        kind,
        payment.amount_cents,
        payment.operation_id,
        payment.occurred_on || fallback_date
      )
    end)
  end

  defp settlement_kind(group, rows) do
    kinds = rows |> Enum.map(& &1.kind) |> Enum.uniq()

    cond do
      kinds == ["held"] and group.status == "active" ->
        "held"

      length(kinds) == 1 and group.status == "cancelled" ->
        hd(kinds)

      true ->
        raise("group #{group.group_id} has inconsistent cash movements for backfill")
    end
  end

  defp insert_movement(group_id, kind, amount_cents, operation_id, occurred_on) do
    Repo.insert!(%CashMovement{
      group_id: group_id,
      kind: kind,
      amount_cents: amount_cents,
      occurred_on: occurred_on,
      operation_id: operation_id
    })
  end

  # The funding sequence for room accounting: the unattributed senior block
  # first (aggregate cash, then legacy credit in consumption order), then
  # durable-operation funding in commit order regardless of occurred_on.
  defp funding_units(%Group{} = group, payments) do
    group_id = group.id

    legacy_cash =
      Repo.one(
        from m in CashMovement,
          where: m.group_id == ^group_id and is_nil(m.operation_id) and m.kind == "held",
          select: coalesce(sum(m.amount_cents), 0)
      ) || 0

    {applications_per_operation, legacy_applications} =
      classify_credit_applications(group.id)

    legacy_units =
      if legacy_cash > 0 do
        [
          %{
            funding_type: "cash",
            source_operation_id: nil,
            credit_lot_id: nil,
            amount_cents: legacy_cash
          }
        ]
      else
        []
      end

    legacy_credit_units =
      Enum.map(legacy_applications, fn application ->
        %{
          funding_type: "credit",
          source_operation_id: nil,
          credit_lot_id: application.credit_lot_id,
          amount_cents: application.amount_cents
        }
      end)

    durable_units =
      durable_funding_records(group.group_id)
      |> Enum.flat_map(fn record ->
        case record.type do
          "record_cash_payment" ->
            payment = Enum.find(payments, &(&1.operation_id == record.operation_id))

            [
              %{
                funding_type: "cash",
                source_operation_id: record.operation_id,
                credit_lot_id: nil,
                amount_cents: payment.amount_cents
              }
            ]

          "apply_hotel_credit" ->
            applications_per_operation
            |> Map.get(record.operation_id, [])
            |> Enum.map(fn application ->
              %{
                funding_type: "credit",
                source_operation_id: record.operation_id,
                credit_lot_id: application.credit_lot_id,
                amount_cents: application.amount_cents
              }
            end)
        end
      end)

    legacy_units ++ legacy_credit_units ++ durable_units
  end

  defp durable_funding_records(group_id) do
    from(r in OperationRecord,
      where: r.type in ["record_cash_payment", "apply_hotel_credit"],
      order_by: [asc: r.id]
    )
    |> Repo.all()
    |> Enum.map(&{&1, Jason.decode!(&1.result)})
    |> Enum.filter(fn {_record, result} ->
      result["status"] == "applied" and result["group_id"] == group_id
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # Legacy credit applications carry no operation identity. Applications were
  # inserted in processing order and durable applications came last, so they
  # are attached to their operations from the tail; whatever remains is the
  # unattributed legacy block.
  defp classify_credit_applications(group_id) do
    applications = legacy_credit_applications(group_id)
    durable_amounts = durable_credit_totals(group_id)

    {per_operation, legacy} =
      attach_applications(applications, Enum.reverse(durable_amounts), %{})

    {per_operation, legacy}
  end

  defp legacy_credit_applications(group_id) do
    # After the room-accounting migration completes, the historical
    # credit_applications table no longer exists; there is nothing legacy left
    # to read.
    with {:ok, %{rows: [["credit_applications"] | _]}} <-
           Repo.query(
             "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'credit_applications'",
             []
           ),
         {:ok, %{} = result} <-
           Repo.query(
             "SELECT credit_lot_id, amount_cents FROM credit_applications WHERE group_id = ? ORDER BY rowid",
             [group_id]
           ) do
      Enum.map(result.rows, fn [credit_lot_id, amount_cents] ->
        %{credit_lot_id: credit_lot_id, amount_cents: amount_cents}
      end)
    else
      _other -> []
    end
  end

  defp durable_credit_totals(group_id) do
    durable_funding_records(group_id)
    |> Enum.filter(&(&1.type == "apply_hotel_credit"))
    |> Enum.map(fn record ->
      {record.operation_id, Jason.decode!(record.result)["amount_cents"]}
    end)
    |> Enum.filter(fn {_operation_id, amount_cents} -> is_integer(amount_cents) end)
  end

  defp attach_applications(applications, [], per_operation),
    do: {per_operation, applications}

  defp attach_applications(applications, [{operation_id, amount} | rest], per_operation) do
    {taken, remaining} = take_from_tail(applications, amount, [])

    attach_applications(
      remaining,
      rest,
      Map.put(per_operation, operation_id, Enum.reverse(taken))
    )
  end

  defp take_from_tail(applications, 0, acc), do: {acc, applications}

  defp take_from_tail([application | rest], amount, acc) do
    cond do
      application.amount_cents < amount ->
        raise("credit application does not align with its durable operation")

      application.amount_cents == amount ->
        {[application | acc], rest}

      true ->
        raise("credit application does not align with its durable operation")
    end
  end

  defp take_from_tail([], _amount, _acc), do: raise("missing credit applications for backfill")
end
