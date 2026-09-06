defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.{
    CreditLot,
    FinanceCashOpening,
    FinanceDailyReportSnapshot,
    FinanceLotOpening,
    FinanceMovement,
    FinanceReporting,
    FundingAllocation,
    Group
  }

  alias GroupStay.Repo

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)
  @tracked_types ~w(record_cash_payment transfer_deposit cancel_group cancel_rooms apply_hotel_credit reduce_cash_payment charge_back_payment)

  def start(starts_on) do
    case Repo.one(from reporting in FinanceReporting, limit: 1) do
      nil -> {:ok, create_inception!(starts_on)}
      _reporting -> {:error, :already_started}
    end
  end

  def close(period_end_on) do
    case Repo.one(from reporting in FinanceReporting, limit: 1) do
      nil ->
        {:error, :invalid_period}

      reporting ->
        valid_start? = Date.compare(period_end_on, reporting.starts_on) != :lt

        later_than_previous? =
          is_nil(reporting.latest_closed_on) or
            Date.after?(period_end_on, reporting.latest_closed_on)

        if valid_start? and later_than_previous? do
          first_new_date =
            if reporting.latest_closed_on,
              do: Date.add(reporting.latest_closed_on, 1),
              else: reporting.starts_on

          Enum.each(Date.range(first_new_date, period_end_on), fn date ->
            data = reporting |> build_report(date, "closed") |> canonical_json()

            %FinanceDailyReportSnapshot{}
            |> FinanceDailyReportSnapshot.changeset(%{
              finance_reporting_id: reporting.id,
              report_on: date,
              data: data
            })
            |> Repo.insert!()
          end)

          reporting =
            reporting
            |> FinanceReporting.changeset(%{latest_closed_on: period_end_on})
            |> Repo.update!()

          {:ok, reporting}
        else
          {:error, :invalid_period}
        end
    end
  end

  def before_operation(%{"type" => type} = operation) when type in @tracked_types do
    case Repo.one(from reporting in FinanceReporting, limit: 1) do
      nil ->
        nil

      reporting ->
        case parse_operation_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            ordinary_posting_on = max_date(occurred_on, reporting.starts_on)

            posting_on =
              if reporting.latest_closed_on,
                do: max_date(ordinary_posting_on, Date.add(reporting.latest_closed_on, 1)),
                else: ordinary_posting_on

            %{
              reporting: reporting,
              posting_on: posting_on,
              late_adjustment: Date.after?(posting_on, ordinary_posting_on),
              snapshot: snapshot()
            }

          {:error, _reason} ->
            nil
        end
    end
  end

  def before_operation(_operation), do: nil

  def after_operation(_operation, _operation_id, result, nil), do: result

  def after_operation(operation, operation_id, result, context) do
    if value(result, "status") == "applied" do
      after_snapshot = snapshot()

      record_cash!(
        operation["type"],
        operation_id,
        context.posting_on,
        context.late_adjustment,
        result,
        context.snapshot,
        after_snapshot
      )

      record_credit!(
        operation,
        operation_id,
        context.posting_on,
        context.late_adjustment,
        result,
        context.snapshot,
        after_snapshot
      )

      record_availability!(
        operation_id,
        context.posting_on,
        context.late_adjustment,
        context.snapshot,
        after_snapshot
      )
    end

    result
  end

  def daily_report(date) do
    case Repo.one(from reporting in FinanceReporting, limit: 1) do
      nil ->
        {:error, :not_available}

      reporting ->
        if Date.before?(date, reporting.starts_on),
          do: {:error, :not_available},
          else: {:ok, report_for_date(reporting, date)}
    end
  end

  defp report_for_date(%FinanceReporting{latest_closed_on: closed_on} = reporting, date)
       when not is_nil(closed_on) do
    if Date.compare(date, closed_on) != :gt do
      Repo.get_by!(FinanceDailyReportSnapshot,
        finance_reporting_id: reporting.id,
        report_on: date
      ).data
    else
      build_report(reporting, date, "open")
    end
  end

  defp report_for_date(reporting, date), do: build_report(reporting, date, "open")

  defp create_inception!(starts_on) do
    reporting =
      %FinanceReporting{}
      |> FinanceReporting.changeset(%{
        starts_on: starts_on,
        opening_credit_liability_cents: credit_liability(starts_on)
      })
      |> Repo.insert!()

    now = DateTime.utc_now()

    cash_openings()
    |> Enum.each(fn {property_id, amount} ->
      Repo.insert_all(FinanceCashOpening, [
        %{
          finance_reporting_id: reporting.id,
          property_id: property_id,
          opening_held_cents: amount,
          inserted_at: now
        }
      ])
    end)

    Repo.all(
      from lot in CreditLot, where: lot.remaining_cents > 0 and lot.expires_on >= ^starts_on
    )
    |> Enum.each(fn lot ->
      Repo.insert_all(FinanceLotOpening, [
        %{
          finance_reporting_id: reporting.id,
          credit_lot_id: lot.id,
          available_cents: lot.remaining_cents,
          inserted_at: now
        }
      ])
    end)

    reporting
  end

  defp snapshot do
    cash =
      Repo.all(
        from allocation in FundingAllocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: allocation.funding_type == "cash",
          group_by: [group.property_id, allocation.disposition],
          select: {{group.property_id, allocation.disposition}, sum(allocation.amount_cents)}
      )
      |> Map.new()

    credit_held =
      Repo.all(
        from allocation in FundingAllocation,
          where: allocation.funding_type == "credit" and allocation.disposition == "held",
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    lots =
      Repo.all(
        from lot in CreditLot,
          select: {lot.id, {lot.remaining_cents, lot.unrecovered_clawback_cents, lot.expires_on}}
      )
      |> Map.new()

    max_allocation_id =
      Repo.one(from allocation in FundingAllocation, select: max(allocation.id)) || 0

    %{cash: cash, credit_held: credit_held, lots: lots, max_allocation_id: max_allocation_id}
  end

  defp record_cash!(
         "transfer_deposit",
         operation_id,
         posting_on,
         late_adjustment,
         result,
         before,
         _after_state
       ) do
    cash_moved =
      Repo.one(
        from allocation in FundingAllocation,
          where:
            allocation.id > ^before.max_allocation_id and allocation.funding_type == "cash" and
              allocation.disposition == "held",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    if cash_moved > 0 do
      source = Repo.get_by!(Group, group_id: value(result, "source_group_id"))
      destination = Repo.get_by!(Group, group_id: value(result, "destination_group_id"))

      insert_movement!(
        operation_id,
        posting_on,
        "transferred_out",
        cash_moved,
        source.property_id,
        nil,
        late_adjustment
      )

      insert_movement!(
        operation_id,
        posting_on,
        "transferred_in",
        cash_moved,
        destination.property_id,
        nil,
        late_adjustment
      )
    end
  end

  defp record_cash!(
         type,
         operation_id,
         posting_on,
         late_adjustment,
         _result,
         before,
         after_state
       ) do
    dispositions = cash_disposition_movements(type)

    properties =
      Map.keys(before.cash)
      |> Enum.concat(Map.keys(after_state.cash))
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    Enum.each(properties, fn property_id ->
      Enum.each(dispositions, fn {disposition, kind, direction} ->
        delta =
          cash_amount(after_state, property_id, disposition) -
            cash_amount(before, property_id, disposition)

        insert_movement!(
          operation_id,
          posting_on,
          kind,
          delta * direction,
          property_id,
          nil,
          late_adjustment
        )
      end)
    end)
  end

  defp cash_disposition_movements("record_cash_payment"), do: [{"held", "received", 1}]

  defp cash_disposition_movements("transfer_deposit"),
    do: [{"held", "transferred", 1}]

  defp cash_disposition_movements(type) when type in ["cancel_group", "cancel_rooms"],
    do: [
      {"refunded", "refunded", 1},
      {"retained", "retained", 1},
      {"converted", "converted_to_credit", 1}
    ]

  defp cash_disposition_movements("reduce_cash_payment"), do: [{"reduced", "reduced", 1}]

  defp cash_disposition_movements("charge_back_payment"),
    do: [
      {"refunded", "refunded", 1},
      {"retained", "retained", 1},
      {"converted", "converted_to_credit", 1},
      {"charged_back", "charged_back", 1}
    ]

  defp cash_disposition_movements(_type), do: []

  defp insert_movement!(
         _operation_id,
         _posting_on,
         _kind,
         0,
         _property_id,
         _lot_id,
         _late_adjustment
       ),
       do: :ok

  defp insert_movement!(
         operation_id,
         posting_on,
         "transferred",
         amount,
         property_id,
         lot_id,
         late_adjustment
       ) do
    kind = if amount > 0, do: "transferred_in", else: "transferred_out"

    insert_movement!(
      operation_id,
      posting_on,
      kind,
      abs(amount),
      property_id,
      lot_id,
      late_adjustment
    )
  end

  defp insert_movement!(
         operation_id,
         posting_on,
         kind,
         amount,
         property_id,
         lot_id,
         late_adjustment
       ) do
    %FinanceMovement{}
    |> FinanceMovement.changeset(%{
      operation_id: operation_id,
      posting_on: posting_on,
      kind: kind,
      amount_cents: amount,
      property_id: property_id,
      late_adjustment: late_adjustment,
      credit_lot_id: lot_id
    })
    |> Repo.insert!()
  end

  defp record_credit!(
         operation,
         operation_id,
         posting_on,
         late_adjustment,
         result,
         before,
         after_state
       ) do
    type = operation["type"]

    if type in ["cancel_group", "cancel_rooms"] do
      issued = value(result, "credit_issued_cents") || 0
      insert_movement!(operation_id, posting_on, "issued", issued, nil, nil, late_adjustment)

      removed = credit_held_total(before) - credit_held_total(after_state)

      if removed > 0 do
        group = Repo.get_by!(Group, group_id: value(result, "group_id"))
        {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

        if refundable?(group, occurred_on) do
          restored = positive_remaining_delta(before, after_state)
          absorbed = positive_clawback_reduction(before, after_state)

          insert_movement!(
            operation_id,
            posting_on,
            "absorbed",
            absorbed,
            nil,
            nil,
            late_adjustment
          )

          insert_movement!(
            operation_id,
            posting_on,
            "expired",
            removed - restored - absorbed,
            nil,
            nil,
            late_adjustment
          )
        else
          insert_movement!(
            operation_id,
            posting_on,
            "consumed",
            removed,
            nil,
            nil,
            late_adjustment
          )
        end
      end
    end

    if type == "charge_back_payment" do
      revoked =
        Enum.reduce(before.lots, 0, fn {lot_id, {remaining, _clawback, expires_on}}, total ->
          {after_remaining, _after_clawback, _expires_on} =
            Map.fetch!(after_state.lots, lot_id)

          removed = max(remaining - after_remaining, 0)
          if Date.compare(posting_on, expires_on) != :gt, do: total + removed, else: total
        end)

      insert_movement!(operation_id, posting_on, "revoked", revoked, nil, nil, late_adjustment)
    end
  end

  defp record_availability!(operation_id, posting_on, late_adjustment, before, after_state) do
    lot_ids = Map.keys(before.lots) |> Enum.concat(Map.keys(after_state.lots)) |> Enum.uniq()

    Enum.each(lot_ids, fn lot_id ->
      before_remaining = before.lots |> Map.get(lot_id, {0, 0, nil}) |> elem(0)
      after_remaining = after_state.lots |> Map.get(lot_id, {0, 0, nil}) |> elem(0)

      insert_movement!(
        operation_id,
        posting_on,
        "credit_available",
        after_remaining - before_remaining,
        nil,
        lot_id,
        late_adjustment
      )
    end)
  end

  defp build_report(reporting, date, status) do
    movements = Repo.all(from movement in FinanceMovement, where: movement.posting_on <= ^date)
    expiries = expiry_movements(reporting, date)
    {cash, late_cash} = build_cash(reporting, movements, date)
    {credit, late_credit} = build_credit(reporting, movements, expiries, date)

    %{
      date: date,
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp build_cash(reporting, movements, date) do
    openings =
      Repo.all(
        from opening in FinanceCashOpening,
          where: opening.finance_reporting_id == ^reporting.id,
          select: {opening.property_id, opening.opening_held_cents}
      )
      |> Map.new()

    cash_movements = Enum.filter(movements, &(&1.kind in @cash_kinds))

    properties =
      Map.keys(openings)
      |> Enum.concat(Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(properties, fn property_id ->
        prior =
          Enum.filter(
            cash_movements,
            &(&1.property_id == property_id and Date.before?(&1.posting_on, date))
          )

        today =
          Enum.filter(cash_movements, &(&1.property_id == property_id and &1.posting_on == date))

        opening = Map.get(openings, property_id, 0) + Enum.sum(Enum.map(prior, &cash_effect/1))
        ordinary = Enum.reject(today, & &1.late_adjustment)
        late = Enum.filter(today, & &1.late_adjustment)
        closing = opening + Enum.sum(Enum.map(today, &cash_effect/1))

        {
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: ordinary |> movement_totals(@cash_kinds) |> cents_keys(),
            closing_held_cents: closing
          },
          %{
            property_id: property_id,
            movements: late |> movement_totals(@cash_kinds) |> cents_keys()
          }
        }
      end)

    cash =
      entries
      |> Enum.reject(fn {entry, late_entry} ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          Enum.all?(entry.movements, fn {_key, amount} -> amount == 0 end) and
          Enum.all?(late_entry.movements, fn {_key, amount} -> amount == 0 end)
      end)
      |> Enum.map(&elem(&1, 0))

    late_cash =
      entries
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(fn entry ->
        Enum.all?(entry.movements, fn {_key, amount} -> amount == 0 end)
      end)

    {cash, late_cash}
  end

  defp build_credit(reporting, movements, expiries, date) do
    public = Enum.filter(movements, &(&1.kind in @credit_kinds)) ++ expiries
    prior = Enum.filter(public, &Date.before?(&1.posting_on, date))
    today = Enum.filter(public, &(&1.posting_on == date))
    ordinary = Enum.reject(today, & &1.late_adjustment)
    late = Enum.filter(today, & &1.late_adjustment)

    opening =
      reporting.opening_credit_liability_cents + Enum.sum(Enum.map(prior, &credit_effect/1))

    closing = opening + Enum.sum(Enum.map(today, &credit_effect/1))

    {
      %{
        opening_liability_cents: opening,
        movements: ordinary |> movement_totals(@credit_kinds) |> cents_keys(),
        closing_liability_cents: closing
      },
      late |> movement_totals(@credit_kinds) |> cents_keys()
    }
  end

  defp expiry_movements(reporting, through_date) do
    openings =
      Repo.all(
        from opening in FinanceLotOpening,
          where: opening.finance_reporting_id == ^reporting.id,
          select: {opening.credit_lot_id, opening.available_cents}
      )
      |> Map.new()

    availability =
      Repo.all(from movement in FinanceMovement, where: movement.kind == "credit_available")

    by_lot = Enum.group_by(availability, & &1.credit_lot_id)
    lot_ids = Map.keys(openings) |> Enum.concat(Map.keys(by_lot)) |> Enum.uniq()

    Repo.all(from lot in CreditLot, where: lot.id in ^lot_ids)
    |> Enum.flat_map(fn lot ->
      lot_events = Map.get(by_lot, lot.id, [])

      first_positive_event =
        lot_events
        |> Enum.filter(&(&1.amount_cents > 0))
        |> Enum.min_by(& &1.id, fn -> nil end)

      first_positive_posting =
        if first_positive_event, do: first_positive_event.posting_on, else: reporting.starts_on

      natural_expiry_on = Date.add(lot.expires_on, 1)
      expiry_on = max_date(natural_expiry_on, first_positive_posting)

      availability_through_expiry =
        if first_positive_event && Date.after?(first_positive_posting, lot.expires_on) do
          Enum.filter(lot_events, &(&1.id <= first_positive_event.id))
        else
          Enum.filter(lot_events, &(Date.compare(&1.posting_on, lot.expires_on) != :gt))
        end

      amount =
        Map.get(openings, lot.id, 0) +
          Enum.sum(Enum.map(availability_through_expiry, & &1.amount_cents))

      late_adjustment =
        first_positive_event != nil and first_positive_event.late_adjustment and
          Date.after?(expiry_on, natural_expiry_on)

      if Date.compare(expiry_on, through_date) != :gt and amount > 0,
        do: [
          %{
            kind: "expired",
            amount_cents: amount,
            posting_on: expiry_on,
            late_adjustment: late_adjustment
          }
        ],
        else: []
    end)
  end

  defp movement_totals(movements, kinds) do
    base = Map.new(kinds, &{&1, 0})

    Enum.reduce(
      movements,
      base,
      &Map.update!(&2, &1.kind, fn amount -> amount + &1.amount_cents end)
    )
  end

  defp cents_keys(map),
    do: Map.new(map, fn {kind, amount} -> {String.to_atom(kind <> "_cents"), amount} end)

  defp cash_effect(%{kind: kind, amount_cents: amount})
       when kind in ["received", "transferred_in"],
       do: amount

  defp cash_effect(%{amount_cents: amount}), do: -amount
  defp credit_effect(%{kind: "issued", amount_cents: amount}), do: amount
  defp credit_effect(%{amount_cents: amount}), do: -amount

  defp cash_openings do
    Repo.all(
      from allocation in FundingAllocation,
        join: group in Group,
        on: group.id == allocation.group_id,
        where: allocation.funding_type == "cash" and allocation.disposition == "held",
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)}
    )
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in FundingAllocation,
          where: allocation.funding_type == "credit" and allocation.disposition == "held",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp cash_amount(snapshot, property_id, disposition),
    do: Map.get(snapshot.cash, {property_id, disposition}, 0)

  defp credit_held_total(snapshot), do: snapshot.credit_held |> Map.values() |> Enum.sum()

  defp positive_remaining_delta(before, after_state) do
    Enum.reduce(before.lots, 0, fn {lot_id, {remaining, _clawback, _expires}}, total ->
      {after_remaining, _after_clawback, _after_expires} = Map.fetch!(after_state.lots, lot_id)
      total + max(after_remaining - remaining, 0)
    end)
  end

  defp positive_clawback_reduction(before, after_state) do
    Enum.reduce(before.lots, 0, fn {lot_id, {_remaining, clawback, _expires}}, total ->
      {_after_remaining, after_clawback, _after_expires} =
        Map.fetch!(after_state.lots, lot_id)

      total + max(clawback - after_clawback, 0)
    end)
  end

  defp refundable?(group, occurred_on) do
    deadline =
      case group.policy_version do
        "flex-14" -> Date.add(group.arrival_on, -14)
        "flex-30" -> Date.add(group.arrival_on, -30)
        "advance-nonrefundable" -> nil
      end

    deadline != nil and Date.compare(occurred_on, deadline) != :gt
  end

  defp max_date(left, right), do: if(Date.compare(left, right) != :lt, do: left, else: right)
  defp parse_operation_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_operation_date(_value), do: {:error, :invalid_date}
  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp canonical_json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
