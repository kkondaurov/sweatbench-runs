defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Credits.Lot
  alias GroupStay.Finance.CreditEvent
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.OpeningCash
  alias GroupStay.Finance.Reporting
  alias GroupStay.Funding.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  def begin!(operation_id, %Date{} = starts_on) when is_binary(operation_id) do
    if started?() do
      {:error, :already_started}
    else
      try do
        insert_inception!(operation_id, starts_on)
        :ok
      rescue
        e in Ecto.ConstraintError ->
          if e.type == :unique, do: {:error, :already_started}, else: reraise(e, __STACKTRACE__)
      end
    end
  end

  def daily_report(%Date{} = date) do
    case Repo.one(Reporting) do
      nil ->
        :not_available

      %Reporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          :not_available
        else
          {:ok, assemble(reporting, date)}
        end
    end
  end

  def record_receipt!(occurred_on, property_id, amount, operation_id) do
    record(fn ->
      insert_movement!(occurred_on, property_id, "cash", "received", amount, operation_id)
    end)
  end

  def record_transfer!(
        occurred_on,
        source_property_id,
        destination_property_id,
        cash,
        operation_id
      ) do
    record(fn ->
      insert_movement!(
        occurred_on,
        source_property_id,
        "cash",
        "transferred_out",
        cash,
        operation_id
      )

      insert_movement!(
        occurred_on,
        destination_property_id,
        "cash",
        "transferred_in",
        cash,
        operation_id
      )
    end)
  end

  def record_reductions!(occurred_on, slices, operation_id) when is_list(slices) do
    record(fn ->
      properties = properties_of(Enum.map(slices, & &1.group_id))

      Enum.each(slices, fn %{group_id: group_id, amount_cents: amount} ->
        insert_movement!(
          occurred_on,
          Map.fetch!(properties, group_id),
          "cash",
          "reduced",
          amount,
          operation_id
        )
      end)
    end)
  end

  def record_chargeback!(occurred_on, per_group, operation_id) when is_map(per_group) do
    record(fn ->
      properties = properties_of(Map.keys(per_group))

      Enum.each(per_group, fn {group_id, deltas} ->
        property_id = Map.fetch!(properties, group_id)
        held = Map.get(deltas, :held_cents, 0)
        refunded = Map.get(deltas, :refunded_cents, 0)
        retained = Map.get(deltas, :retained_cents, 0)
        converted = Map.get(deltas, :converted_cents, 0)

        insert_movement!(
          occurred_on,
          property_id,
          "cash",
          "charged_back",
          held + refunded + retained + converted,
          operation_id
        )

        insert_movement!(occurred_on, property_id, "cash", "refunded", -refunded, operation_id)
        insert_movement!(occurred_on, property_id, "cash", "retained", -retained, operation_id)

        insert_movement!(
          occurred_on,
          property_id,
          "cash",
          "converted_to_credit",
          -converted,
          operation_id
        )
      end)
    end)
  end

  def record_applications!(occurred_on, draws, operation_id) when is_list(draws) do
    record(fn ->
      Enum.each(draws, fn %{lot_id: lot_id, amount_cents: amount} ->
        note_remaining!(occurred_on, lot_id, "apply", amount, operation_id)
      end)
    end)
  end

  def record_revoke!(occurred_on, lot_id, removed, operation_id)
      when is_integer(removed) and removed > 0 do
    record(fn ->
      lot = Repo.get!(Lot, lot_id)
      note_remaining!(occurred_on, lot.id, "revoke", removed, operation_id)

      if revoke_counts?(lot.expires_on, occurred_on) do
        insert_movement!(occurred_on, nil, "credit", "revoked", removed, operation_id)
      end
    end)
  end

  def record_revoke!(_occurred_on, _lot_id, _removed, _operation_id), do: :ok

  def record_settlement!(
        occurred_on,
        property_id,
        settlement,
        lot,
        applied_credit,
        restore,
        operation_id
      ) do
    record(fn ->
      insert_movement!(
        occurred_on,
        property_id,
        "cash",
        "refunded",
        settlement.refunded_cents,
        operation_id
      )

      insert_movement!(
        occurred_on,
        property_id,
        "cash",
        "retained",
        settlement.retained_cents,
        operation_id
      )

      insert_movement!(
        occurred_on,
        property_id,
        "cash",
        "converted_to_credit",
        settlement.cash_converted_cents,
        operation_id
      )

      if lot do
        record_issue!(occurred_on, lot, settlement.credit_issued_cents, operation_id)
      end

      case restore do
        nil ->
          insert_movement!(occurred_on, nil, "credit", "consumed", applied_credit, operation_id)

        totals ->
          insert_movement!(
            occurred_on,
            nil,
            "credit",
            "absorbed",
            totals.absorbed_cents,
            operation_id
          )

          insert_movement!(
            occurred_on,
            nil,
            "credit",
            "expired",
            totals.expired_cents,
            operation_id
          )

          Enum.each(totals.restored, fn draw ->
            lot = Repo.get!(Lot, draw.lot_id)

            if Date.compare(posting_on(occurred_on), lot.expires_on) == :gt do
              insert_movement!(
                occurred_on,
                nil,
                "credit",
                "expired",
                draw.amount_cents,
                operation_id
              )
            else
              note_remaining!(
                occurred_on,
                draw.lot_id,
                "restore_available",
                draw.amount_cents,
                operation_id
              )
            end
          end)
      end
    end)
  end

  defp record(fun) do
    if started?(), do: fun.(), else: :ok
  end

  defp started?, do: Repo.exists?(Reporting)

  defp insert_inception!(operation_id, starts_on) do
    %Reporting{}
    |> Reporting.changeset(%{
      singleton: 1,
      operation_id: operation_id,
      starts_on: starts_on,
      opening_liability_cents: Credits.liability(starts_on)
    })
    |> Repo.insert!()

    Enum.each(held_by_property(), fn {property_id, held} ->
      %OpeningCash{}
      |> OpeningCash.changeset(%{property_id: property_id, held_cents: held})
      |> Repo.insert!()
    end)
  end

  defp held_by_property do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.disposition == "held",
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
    |> Enum.map(fn {property_id, held} -> {property_id, money(held)} end)
    |> Enum.filter(fn {_property_id, held} -> held > 0 end)
  end

  defp money(value) when is_integer(value), do: value
  defp money(nil), do: 0

  defp record_issue!(occurred_on, lot, amount, operation_id) do
    insert_movement!(occurred_on, nil, "credit", "issued", amount, operation_id)
    note_remaining!(occurred_on, lot.id, "issue", amount, operation_id)

    if Date.compare(posting_on(occurred_on), lot.expires_on) == :gt do
      insert_movement!(occurred_on, nil, "credit", "expired", amount, operation_id)
    end
  end

  defp revoke_counts?(expires_on, occurred_on) do
    %Reporting{starts_on: starts_on} = Repo.one!(Reporting)
    posting = posting_on(occurred_on)

    Date.compare(expires_on, starts_on) == :gt and Date.compare(posting, expires_on) != :gt
  end

  defp posting_on(%Date{} = occurred_on) do
    %Reporting{starts_on: starts_on} = Repo.one!(Reporting)
    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  defp insert_movement!(occurred_on, property_id, bucket, kind, amount, operation_id)
       when is_integer(amount) and amount != 0 do
    %Movement{}
    |> Movement.changeset(%{
      posting_on: posting_on(occurred_on),
      property_id: property_id,
      bucket: bucket,
      kind: kind,
      amount_cents: amount,
      operation_id: operation_id
    })
    |> Repo.insert!()

    :ok
  end

  defp insert_movement!(_occurred_on, _property_id, _bucket, _kind, _amount, _operation_id),
    do: :ok

  defp note_remaining!(occurred_on, lot_id, kind, amount, operation_id)
       when is_integer(amount) and amount > 0 do
    %CreditEvent{}
    |> CreditEvent.changeset(%{
      credit_lot_id: lot_id,
      posting_on: posting_on(occurred_on),
      kind: kind,
      amount_cents: amount,
      operation_id: operation_id
    })
    |> Repo.insert!()

    :ok
  end

  defp note_remaining!(_occurred_on, _lot_id, _kind, _amount, _operation_id), do: :ok

  defp properties_of(group_ids) do
    ids = Enum.uniq(group_ids)

    Repo.all(from g in Group, where: g.id in ^ids, select: {g.id, g.property_id})
    |> Map.new()
  end

  defp assemble(%Reporting{} = reporting, date) do
    movements = Repo.all(Movement)
    events = Repo.all(CreditEvent)
    lots = Repo.all(from l in Lot, where: l.expires_on > ^reporting.starts_on)
    openings = Repo.all(OpeningCash) |> Map.new(&{&1.property_id, &1.held_cents})

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash_entries(openings, movements, date),
      credit: credit_entry(reporting, movements, events, lots, date)
    }
  end

  defp cash_entries(openings, movements, date) do
    prior = cash_prior_held(movements, date)
    today = cash_today(movements, date)

    (Map.keys(openings) ++ Map.keys(prior) ++ Map.keys(today))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn property_id ->
      opening = Map.get(openings, property_id, 0) + Map.get(prior, property_id, 0)
      moves = cash_movement_map(Map.get(today, property_id, %{}))
      closing = closing_held(opening, moves)

      if visible_cash?(opening, moves, closing) do
        [
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: moves,
            closing_held_cents: closing
          }
        ]
      else
        []
      end
    end)
  end

  defp cash_prior_held(movements, date) do
    movements
    |> Enum.filter(&(&1.bucket == "cash" and Date.compare(&1.posting_on, date) == :lt))
    |> Enum.reduce(%{}, fn movement, acc ->
      Map.update(acc, movement.property_id, held_effect(movement), &(&1 + held_effect(movement)))
    end)
  end

  defp cash_today(movements, date) do
    movements
    |> Enum.filter(&(&1.bucket == "cash" and Date.compare(&1.posting_on, date) == :eq))
    |> Enum.group_by(& &1.property_id)
    |> Map.new(fn {property_id, rows} -> {property_id, sum_kinds(rows)} end)
  end

  defp held_effect(%{kind: "received", amount_cents: amount}), do: amount
  defp held_effect(%{kind: "transferred_in", amount_cents: amount}), do: amount
  defp held_effect(%{amount_cents: amount}), do: -amount

  defp closing_held(opening, moves) do
    opening + moves.received_cents + moves.transferred_in_cents - moves.transferred_out_cents -
      moves.refunded_cents - moves.retained_cents - moves.converted_to_credit_cents -
      moves.reduced_cents - moves.charged_back_cents
  end

  defp visible_cash?(opening, moves, closing) do
    opening != 0 or closing != 0 or Enum.any?(Map.values(moves), &(&1 != 0))
  end

  defp cash_movement_map(amounts) do
    %{
      received_cents: Map.get(amounts, "received", 0),
      transferred_in_cents: Map.get(amounts, "transferred_in", 0),
      transferred_out_cents: Map.get(amounts, "transferred_out", 0),
      refunded_cents: Map.get(amounts, "refunded", 0),
      retained_cents: Map.get(amounts, "retained", 0),
      converted_to_credit_cents: Map.get(amounts, "converted_to_credit", 0),
      reduced_cents: Map.get(amounts, "reduced", 0),
      charged_back_cents: Map.get(amounts, "charged_back", 0)
    }
  end

  defp credit_entry(reporting, movements, events, lots, date) do
    prior = credit_nets(movements, date, :before)
    today = credit_nets(movements, date, :on)
    prior_expiry = expiry_amount(lots, events, reporting.starts_on, date, :before)
    today_expiry = expiry_amount(lots, events, reporting.starts_on, date, :on)

    opening = reporting.opening_liability_cents + liability_delta(prior) - prior_expiry
    moves = credit_movement_map(today, today_expiry)
    closing = closing_liability(opening, moves)

    %{
      opening_liability_cents: opening,
      movements: moves,
      closing_liability_cents: closing
    }
  end

  defp credit_nets(movements, date, which) do
    movements
    |> Enum.filter(fn movement ->
      movement.bucket == "credit" and
        case which do
          :before -> Date.compare(movement.posting_on, date) == :lt
          :on -> Date.compare(movement.posting_on, date) == :eq
        end
    end)
    |> sum_kinds()
  end

  defp liability_delta(nets) do
    Map.get(nets, "issued", 0) - Map.get(nets, "expired", 0) - Map.get(nets, "consumed", 0) -
      Map.get(nets, "revoked", 0) - Map.get(nets, "absorbed", 0)
  end

  defp closing_liability(opening, moves) do
    opening + moves.issued_cents - moves.expired_cents - moves.consumed_cents -
      moves.revoked_cents -
      moves.absorbed_cents
  end

  defp credit_movement_map(amounts, expiry) do
    %{
      issued_cents: Map.get(amounts, "issued", 0),
      expired_cents: Map.get(amounts, "expired", 0) + expiry,
      consumed_cents: Map.get(amounts, "consumed", 0),
      revoked_cents: Map.get(amounts, "revoked", 0),
      absorbed_cents: Map.get(amounts, "absorbed", 0)
    }
  end

  defp expiry_amount(lots, events, starts_on, date, which) do
    Enum.reduce(lots, 0, fn lot, acc ->
      expiry_on = Date.add(lot.expires_on, 1)

      counted? =
        Date.compare(lot.expires_on, starts_on) == :gt and
          case which do
            :before ->
              Date.compare(expiry_on, date) == :lt

            :on ->
              Date.compare(expiry_on, date) == :eq
          end

      if counted?, do: acc + unused_through(lot, events), else: acc
    end)
  end

  defp unused_through(lot, events) do
    later =
      Enum.reduce(events, 0, fn event, sum ->
        if event.credit_lot_id == lot.id and Date.compare(event.posting_on, lot.expires_on) == :gt do
          sum + signed_delta(event)
        else
          sum
        end
      end)

    lot.remaining_cents - later
  end

  defp signed_delta(%{kind: "issue", amount_cents: amount}), do: amount
  defp signed_delta(%{kind: "restore_available", amount_cents: amount}), do: amount
  defp signed_delta(%{kind: "apply", amount_cents: amount}), do: -amount
  defp signed_delta(%{kind: "revoke", amount_cents: amount}), do: -amount

  defp sum_kinds(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.update(acc, row.kind, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end
end
