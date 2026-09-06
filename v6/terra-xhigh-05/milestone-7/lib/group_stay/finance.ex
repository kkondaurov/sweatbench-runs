defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.CancellationPolicy
  alias GroupStay.Finance.{ClosedDailyReport, PeriodClose}
  alias GroupStay.Groups.{CreditApplication, CreditLot, Group, Room, RoomCreditAllocation}
  alias GroupStay.Repo

  @cash_kinds [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]

  @credit_kinds ["issued", "expired", "consumed", "revoked", "absorbed"]

  def reporting do
    case Repo.one(
           from(setting in "finance_reporting_settings",
             select: %{starts_on: field(setting, :starts_on)}
           )
         ) do
      %{starts_on: starts_on} when is_binary(starts_on) ->
        case Date.from_iso8601(starts_on) do
          {:ok, date} -> %{starts_on: date}
          {:error, _reason} -> nil
        end

      setting ->
        setting
    end
  end

  def start_reporting(starts_on) do
    case reporting() do
      nil ->
        now = now()
        snapshot = snapshot()

        Repo.insert_all("finance_reporting_settings", [
          %{singleton: 1, starts_on: starts_on, inserted_at: now, updated_at: now}
        ])

        cash_openings(snapshot)
        |> Enum.map(fn {property_id, held_cents} ->
          %{
            property_id: property_id,
            held_cents: held_cents,
            inserted_at: now,
            updated_at: now
          }
        end)
        |> insert_all("finance_reporting_cash_openings")

        credit_lot_openings(starts_on)
        |> Enum.map(fn opening ->
          Map.merge(opening, %{inserted_at: now, updated_at: now})
        end)
        |> insert_all("finance_reporting_credit_lot_openings")

        :ok

      _setting ->
        {:error, "reporting_already_started"}
    end
  end

  def close_period(period_end_on) do
    with %{starts_on: starts_on} <- reporting(),
         :ok <- valid_period_end(starts_on, period_end_on),
         :ok <- later_than_latest_close(period_end_on) do
      now = now()

      closed_report_rows(starts_on, period_end_on, now)
      |> insert_closed_reports()

      %PeriodClose{}
      |> PeriodClose.changeset(%{period_end_on: period_end_on})
      |> Repo.insert!()

      :ok
    else
      _ -> {:error, "invalid_period"}
    end
  end

  # This is deliberately a small operational snapshot, not an alternate
  # ledger.  It contains the parts that can change in one operation and makes
  # cash corrections follow the group where the cash was held or settled.
  def snapshot do
    groups =
      Repo.all(
        from(group in Group,
          left_join: room in Room,
          on: room.reservation_id == group.id and room.status == "active",
          group_by: group.id,
          select: %{
            id: group.id,
            group_id: group.group_id,
            property_id: group.property_id,
            held_cents: coalesce(sum(room.cash_paid_cents), 0),
            refunded_cents: group.cancelled_refunded_cents,
            retained_cents: group.cancelled_retained_cents,
            converted_cents: group.cancelled_cash_converted_to_credit_cents
          }
        )
      )
      |> Map.new(&{&1.id, &1})

    lots =
      Repo.all(
        from(lot in CreditLot,
          select: %{
            id: lot.id,
            remaining_cents: lot.remaining_cents,
            unrecovered_cents: lot.unrecovered_clawback_cents,
            expires_on: lot.expires_on
          }
        )
      )
      |> Map.new(&{&1.id, &1})

    applied_by_lot = applied_credit_by_lot()

    %{groups: groups, lots: lots, applied_by_lot: applied_by_lot}
  end

  def record_operation(operation, result, before) do
    case reporting() do
      nil ->
        :ok

      %{starts_on: starts_on} ->
        {posting_on, late_adjustment?} = posting_date(operation, starts_on)
        after_snapshot = snapshot()
        operation_id = operation["operation_id"]

        case operation["type"] do
          "record_cash_payment" ->
            record_received(
              operation_id,
              posting_on,
              late_adjustment?,
              before,
              after_snapshot,
              result
            )

          "cancel_group" ->
            record_cancellation(
              operation,
              operation_id,
              posting_on,
              late_adjustment?,
              before,
              after_snapshot,
              result
            )

          "cancel_rooms" ->
            record_cancellation(
              operation,
              operation_id,
              posting_on,
              late_adjustment?,
              before,
              after_snapshot,
              result
            )

          "apply_hotel_credit" ->
            record_credit_application(operation_id, posting_on, before, after_snapshot)

          "reduce_cash_payment" ->
            record_reduction(operation_id, posting_on, late_adjustment?, before, after_snapshot)

          "charge_back_payment" ->
            record_chargeback(operation_id, posting_on, late_adjustment?, before, after_snapshot)

          "transfer_deposit" ->
            record_transfer(
              operation_id,
              posting_on,
              late_adjustment?,
              before,
              after_snapshot,
              result
            )

          _ ->
            :ok
        end
    end
  end

  def daily_report(date) do
    with %{starts_on: starts_on} <- reporting(),
         :ok <- available_on(date, starts_on) do
      case Repo.get_by(ClosedDailyReport, report_on: date) do
        %ClosedDailyReport{report_data: report_data} -> {:ok, report_data}
        nil -> {:ok, report_for(date, "open")}
      end
    else
      nil -> :not_available
      {:error, :not_available} -> :not_available
    end
  end

  defp report_for(date, status) do
    {cash, late_cash} = cash_report(date)
    {credit, late_credit} = credit_report(date)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp valid_period_end(starts_on, period_end_on) do
    if Date.compare(period_end_on, starts_on) in [:eq, :gt], do: :ok, else: :invalid_period
  end

  defp later_than_latest_close(period_end_on) do
    case latest_period_end() do
      nil -> :ok
      latest -> if Date.compare(period_end_on, latest) == :gt, do: :ok, else: :invalid_period
    end
  end

  defp latest_period_end do
    Repo.one(
      from(close in PeriodClose,
        order_by: [desc: close.period_end_on],
        limit: 1,
        select: close.period_end_on
      )
    )
  end

  defp closed_report_rows(starts_on, period_end_on, now) do
    first_unpublished_on =
      case latest_period_end() do
        nil -> starts_on
        latest -> Date.add(latest, 1)
      end

    Date.range(first_unpublished_on, period_end_on)
    |> Enum.map(fn report_on ->
      %{
        report_on: report_on,
        report_data: report_for(report_on, "closed"),
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp insert_closed_reports([]), do: :ok

  defp insert_closed_reports(reports), do: Repo.insert_all(ClosedDailyReport, reports)

  defp available_on(date, starts_on) do
    if Date.compare(date, starts_on) == :lt, do: {:error, :not_available}, else: :ok
  end

  defp cash_openings(snapshot) do
    snapshot.groups
    |> Map.values()
    |> Enum.group_by(& &1.property_id, & &1.held_cents)
    |> Map.new(fn {property_id, amounts} -> {property_id, Enum.sum(amounts)} end)
    |> Enum.reject(fn {_property_id, held_cents} -> held_cents == 0 end)
  end

  defp credit_lot_openings(starts_on) do
    lots = snapshot().lots
    applied = applied_credit_by_lot()

    lots
    |> Map.values()
    |> Enum.map(fn lot ->
      available_cents =
        if Date.compare(lot.expires_on, starts_on) == :lt, do: 0, else: lot.remaining_cents

      %{
        credit_lot_id: lot.id,
        available_cents: available_cents,
        applied_cents: Map.get(applied, lot.id, 0),
        expires_on: lot.expires_on
      }
    end)
    |> Enum.filter(fn opening -> opening.available_cents > 0 or opening.applied_cents > 0 end)
  end

  defp applied_credit_by_lot do
    Repo.all(
      from(allocation in RoomCreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: application in CreditApplication,
        on: application.id == allocation.credit_application_id,
        where: room.status == "active",
        group_by: application.credit_lot_id,
        select: {application.credit_lot_id, coalesce(sum(allocation.amount_cents), 0)}
      )
    )
    |> Map.new()
  end

  defp record_received(operation_id, posting_on, late_adjustment?, before, after_snapshot, result) do
    group_id = map_value(result, :group_id)
    amount = group_change(before, after_snapshot, group_id, :held_cents)

    if amount > 0 do
      movement(
        operation_id,
        posting_on,
        "cash",
        "received",
        group_property(after_snapshot, before, group_id),
        amount,
        late_adjustment?
      )
    end
  end

  defp record_cancellation(
         operation,
         operation_id,
         posting_on,
         late_adjustment?,
         before,
         after_snapshot,
         result
       ) do
    group_id = map_value(result, :group_id)
    property_id = group_property(after_snapshot, before, group_id)

    Enum.each(
      [
        {"refunded", group_change(before, after_snapshot, group_id, :refunded_cents)},
        {"retained", group_change(before, after_snapshot, group_id, :retained_cents)},
        {"converted_to_credit", group_change(before, after_snapshot, group_id, :converted_cents)}
      ],
      fn {kind, amount} ->
        movement(operation_id, posting_on, "cash", kind, property_id, amount, late_adjustment?)
      end
    )

    record_cancellation_credit(
      operation,
      operation_id,
      posting_on,
      late_adjustment?,
      before,
      after_snapshot,
      result,
      group_id
    )
  end

  defp record_cancellation_credit(
         operation,
         operation_id,
         posting_on,
         late_adjustment?,
         before,
         after_snapshot,
         result,
         group_id
       ) do
    occurred_on = operation_date(operation)
    group = Repo.get_by(Group, group_id: group_id)

    refundable? =
      match?(%Group{}, group) and
        CancellationPolicy.refundable?(group.policy_version, group.arrival_on, occurred_on)

    lost_by_lot = applied_losses(before.applied_by_lot, after_snapshot.applied_by_lot)

    if refundable? do
      {absorbed_cents, expired_cents} =
        Enum.reduce(lost_by_lot, {0, 0}, fn {lot_id, amount}, {absorbed, expired} ->
          before_lot = Map.fetch!(before.lots, lot_id)
          after_lot = Map.fetch!(after_snapshot.lots, lot_id)
          absorbed_amount = max(before_lot.unrecovered_cents - after_lot.unrecovered_cents, 0)

          expired_amount =
            if Date.compare(before_lot.expires_on, occurred_on) == :lt,
              do: amount - absorbed_amount,
              else: 0

          available_amount = amount - absorbed_amount - expired_amount

          credit_lot_event(
            operation_id,
            lot_id,
            posting_on,
            available_amount,
            -amount
          )

          {absorbed + absorbed_amount, expired + expired_amount}
        end)

      movement(
        operation_id,
        posting_on,
        "credit",
        "absorbed",
        nil,
        absorbed_cents,
        late_adjustment?
      )

      movement(
        operation_id,
        posting_on,
        "credit",
        "expired",
        nil,
        expired_cents,
        late_adjustment?
      )
    else
      consumed_cents = Enum.sum(Map.values(lost_by_lot))

      Enum.each(lost_by_lot, fn {lot_id, amount} ->
        credit_lot_event(operation_id, lot_id, posting_on, 0, -amount)
      end)

      movement(
        operation_id,
        posting_on,
        "credit",
        "consumed",
        nil,
        consumed_cents,
        late_adjustment?
      )
    end

    issued_cents = map_value(result, :credit_issued_cents) || 0

    if issued_cents > 0 do
      case Repo.get_by(CreditLot, source_operation_id: operation_id) do
        nil ->
          :ok

        lot ->
          available_cents =
            if Date.compare(lot.expires_on, posting_on) == :lt, do: 0, else: issued_cents

          expired_cents = issued_cents - available_cents

          credit_lot_event(operation_id, lot.id, posting_on, available_cents, 0)

          movement(
            operation_id,
            posting_on,
            "credit",
            "issued",
            nil,
            issued_cents,
            late_adjustment?
          )

          movement(
            operation_id,
            posting_on,
            "credit",
            "expired",
            nil,
            expired_cents,
            late_adjustment?
          )
      end
    end
  end

  defp record_credit_application(operation_id, posting_on, before, after_snapshot) do
    after_snapshot.applied_by_lot
    |> Enum.reduce(0, fn {lot_id, after_applied}, total ->
      applied_cents = after_applied - Map.get(before.applied_by_lot, lot_id, 0)

      if applied_cents > 0 do
        credit_lot_event(operation_id, lot_id, posting_on, -applied_cents, applied_cents)
      end

      total
    end)
  end

  defp record_reduction(operation_id, posting_on, late_adjustment?, before, after_snapshot) do
    (Map.values(before.groups) ++ Map.values(after_snapshot.groups))
    |> Enum.map(& &1.group_id)
    |> MapSet.new()
    |> Enum.each(fn group_id ->
      held_removed = -group_change(before, after_snapshot, group_id, :held_cents)

      movement(
        operation_id,
        posting_on,
        "cash",
        "reduced",
        group_property(after_snapshot, before, group_id),
        held_removed,
        late_adjustment?
      )
    end)
  end

  defp record_chargeback(operation_id, posting_on, late_adjustment?, before, after_snapshot) do
    (Map.values(before.groups) ++ Map.values(after_snapshot.groups))
    |> Enum.map(& &1.group_id)
    |> MapSet.new()
    |> Enum.each(fn group_id ->
      property_id = group_property(after_snapshot, before, group_id)
      held_cents = -group_change(before, after_snapshot, group_id, :held_cents)
      refunded_cents = group_change(before, after_snapshot, group_id, :refunded_cents)
      retained_cents = group_change(before, after_snapshot, group_id, :retained_cents)
      converted_cents = group_change(before, after_snapshot, group_id, :converted_cents)

      movement(
        operation_id,
        posting_on,
        "cash",
        "refunded",
        property_id,
        refunded_cents,
        late_adjustment?
      )

      movement(
        operation_id,
        posting_on,
        "cash",
        "retained",
        property_id,
        retained_cents,
        late_adjustment?
      )

      movement(
        operation_id,
        posting_on,
        "cash",
        "converted_to_credit",
        property_id,
        converted_cents,
        late_adjustment?
      )

      movement(
        operation_id,
        posting_on,
        "cash",
        "charged_back",
        property_id,
        held_cents - refunded_cents - retained_cents - converted_cents,
        late_adjustment?
      )
    end)

    before.lots
    |> Enum.each(fn {lot_id, before_lot} ->
      case Map.fetch(after_snapshot.lots, lot_id) do
        {:ok, after_lot} ->
          revoked_cents = max(before_lot.remaining_cents - after_lot.remaining_cents, 0)

          if Date.compare(before_lot.expires_on, posting_on) != :lt do
            credit_lot_event(operation_id, lot_id, posting_on, -revoked_cents, 0)

            movement(
              operation_id,
              posting_on,
              "credit",
              "revoked",
              nil,
              revoked_cents,
              late_adjustment?
            )
          end

        :error ->
          :ok
      end
    end)
  end

  defp record_transfer(
         operation_id,
         posting_on,
         late_adjustment?,
         before,
         after_snapshot,
         result
       ) do
    source_group_id = map_value(result, :source_group_id)
    destination_group_id = map_value(result, :destination_group_id)
    transferred_cash = -group_change(before, after_snapshot, source_group_id, :held_cents)

    if transferred_cash > 0 do
      movement(
        operation_id,
        posting_on,
        "cash",
        "transferred_out",
        group_property(after_snapshot, before, source_group_id),
        transferred_cash,
        late_adjustment?
      )

      movement(
        operation_id,
        posting_on,
        "cash",
        "transferred_in",
        group_property(after_snapshot, before, destination_group_id),
        transferred_cash,
        late_adjustment?
      )
    end
  end

  defp cash_report(date) do
    openings = cash_opening_balances()
    before = cash_movements_before(date, false)
    late_before = cash_movements_before(date, true)
    daily = cash_movements_on(date, false)
    late_daily = cash_movements_on(date, true)

    properties =
      Map.keys(openings) ++
        Map.keys(before) ++
        Map.keys(late_before) ++
        Map.keys(daily) ++
        Map.keys(late_daily)

    cash =
      properties
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property_id ->
        ordinary_before = cash_movement_shape(Map.get(before, property_id, %{}))
        late_before_movements = cash_movement_shape(Map.get(late_before, property_id, %{}))
        movements = cash_movement_shape(Map.get(daily, property_id, %{}))
        late_movements = cash_movement_shape(Map.get(late_daily, property_id, %{}))

        opening_held_cents =
          Map.get(openings, property_id, 0) +
            held_effect(ordinary_before) + held_effect(late_before_movements)

        closing_held_cents =
          opening_held_cents + held_effect(movements) + held_effect(late_movements)

        %{
          property_id: property_id,
          opening_held_cents: opening_held_cents,
          movements: movements,
          closing_held_cents: closing_held_cents
        }
      end)
      |> Enum.reject(fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end) and
          Enum.all?(
            cash_movement_shape(Map.get(late_daily, entry.property_id, %{})),
            fn {_kind, amount} -> amount == 0 end
          )
      end)

    late_cash =
      late_daily
      |> Enum.sort_by(fn {property_id, _movements} -> property_id end)
      |> Enum.map(fn {property_id, late_movements} ->
        %{property_id: property_id, movements: cash_movement_shape(late_movements)}
      end)
      |> Enum.reject(fn entry ->
        Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end)
      end)

    {cash, late_cash}
  end

  defp credit_report(date) do
    opening_liability_cents =
      credit_opening() + credit_effect(credit_movements_before(date, false)) +
        credit_effect(credit_movements_before(date, true))

    movements = credit_movement_shape(credit_movements_on(date, false), automatic_expiry_on(date))
    late_adjustments = credit_movement_shape(credit_movements_on(date, true), 0)

    {%{
       opening_liability_cents: opening_liability_cents,
       movements: movements,
       closing_liability_cents:
         opening_liability_cents + credit_effect(movements) + credit_effect(late_adjustments)
     }, late_adjustments}
  end

  defp cash_opening_balances do
    Repo.all(
      from(opening in "finance_reporting_cash_openings",
        select: {field(opening, :property_id), field(opening, :held_cents)}
      )
    )
    |> Map.new()
  end

  defp credit_opening do
    Repo.one(
      from(opening in "finance_reporting_credit_lot_openings",
        select:
          coalesce(sum(field(opening, :available_cents) + field(opening, :applied_cents)), 0)
      )
    )
  end

  defp cash_movements_before(date, late_adjustment?),
    do: cash_movements(:lt, date, late_adjustment?)

  defp cash_movements_on(date, late_adjustment?), do: cash_movements(:eq, date, late_adjustment?)

  defp cash_movements(comparison, date, late_adjustment?) do
    where_clause =
      case comparison do
        :lt -> dynamic([movement], movement.posting_on < ^date)
        :eq -> dynamic([movement], movement.posting_on == ^date)
      end

    from(movement in "finance_reporting_movements",
      where:
        field(movement, :currency) == "cash" and
          field(movement, :late_adjustment) == ^late_adjustment?,
      group_by: [field(movement, :property_id), field(movement, :kind)],
      select: {
        field(movement, :property_id),
        field(movement, :kind),
        coalesce(sum(field(movement, :amount_cents)), 0)
      }
    )
    |> where(^where_clause)
    |> Repo.all()
    |> Enum.reduce(%{}, fn {property_id, kind, amount}, balances ->
      Map.update(balances, property_id, %{kind => amount}, &Map.put(&1, kind, amount))
    end)
  end

  defp credit_movements_before(date, late_adjustment?),
    do: credit_movements(:lt, date, late_adjustment?)

  defp credit_movements_on(date, late_adjustment?),
    do: credit_movements(:eq, date, late_adjustment?)

  defp credit_movements(comparison, date, late_adjustment?) do
    where_clause =
      case comparison do
        :lt -> dynamic([movement], movement.posting_on < ^date)
        :eq -> dynamic([movement], movement.posting_on == ^date)
      end

    from(movement in "finance_reporting_movements",
      where:
        field(movement, :currency) == "credit" and
          field(movement, :late_adjustment) == ^late_adjustment?,
      group_by: field(movement, :kind),
      select: {field(movement, :kind), coalesce(sum(field(movement, :amount_cents)), 0)}
    )
    |> where(^where_clause)
    |> Repo.all()
    |> Map.new()
    |> maybe_add_expired_before(date, comparison, late_adjustment?)
  end

  defp maybe_add_expired_before(movements, date, :lt, false),
    do: add_expired_before(movements, date)

  defp maybe_add_expired_before(movements, _date, _comparison, _late_adjustment?), do: movements

  defp add_expired_before(movements, date) do
    reporting()
    |> case do
      %{starts_on: starts_on} ->
        automatic =
          if Date.compare(date, starts_on) == :gt do
            starts_on
            |> Date.range(Date.add(date, -1))
            |> Enum.sum_by(&automatic_expiry_on/1)
          else
            0
          end

        Map.update(movements, "expired", automatic, &(&1 + automatic))

      nil ->
        movements
    end
  end

  defp automatic_expiry_on(date) do
    expires_on = Date.add(date, -1)

    lot_ids =
      Repo.all(from(lot in CreditLot, where: lot.expires_on == ^expires_on, select: lot.id))

    if lot_ids == [] do
      0
    else
      opening_available =
        Repo.all(
          from(opening in "finance_reporting_credit_lot_openings",
            where: field(opening, :credit_lot_id) in ^lot_ids,
            select: {field(opening, :credit_lot_id), field(opening, :available_cents)}
          )
        )
        |> Map.new()

      event_deltas =
        Repo.all(
          from(event in "finance_reporting_credit_lot_events",
            # A late operation becomes effective for reporting on the
            # first open day. Include that day's availability transfer
            # before deciding whether unused credit expires there.
            where:
              field(event, :credit_lot_id) in ^lot_ids and
                field(event, :posting_on) <= ^date,
            group_by: field(event, :credit_lot_id),
            select:
              {field(event, :credit_lot_id),
               coalesce(sum(field(event, :available_delta_cents)), 0)}
          )
        )
        |> Map.new()

      lot_ids
      |> Enum.sum_by(fn lot_id ->
        max(Map.get(opening_available, lot_id, 0) + Map.get(event_deltas, lot_id, 0), 0)
      end)
    end
  end

  defp cash_movement_shape(movements) do
    Map.new(@cash_kinds, fn kind -> {kind, Map.get(movements, kind, 0)} end)
    |> Map.new(fn
      {"received", amount} -> {:received_cents, amount}
      {"transferred_in", amount} -> {:transferred_in_cents, amount}
      {"transferred_out", amount} -> {:transferred_out_cents, amount}
      {"refunded", amount} -> {:refunded_cents, amount}
      {"retained", amount} -> {:retained_cents, amount}
      {"converted_to_credit", amount} -> {:converted_to_credit_cents, amount}
      {"reduced", amount} -> {:reduced_cents, amount}
      {"charged_back", amount} -> {:charged_back_cents, amount}
    end)
  end

  defp credit_movement_shape(movements, automatic_expired) do
    Map.new(@credit_kinds, fn kind -> {kind, Map.get(movements, kind, 0)} end)
    |> Map.update!("expired", &(&1 + automatic_expired))
    |> Map.new(fn
      {"issued", amount} -> {:issued_cents, amount}
      {"expired", amount} -> {:expired_cents, amount}
      {"consumed", amount} -> {:consumed_cents, amount}
      {"revoked", amount} -> {:revoked_cents, amount}
      {"absorbed", amount} -> {:absorbed_cents, amount}
    end)
  end

  defp held_effect(movements) do
    Map.get(movements, :received_cents, 0) + Map.get(movements, :transferred_in_cents, 0) -
      Map.get(movements, :transferred_out_cents, 0) - Map.get(movements, :refunded_cents, 0) -
      Map.get(movements, :retained_cents, 0) - Map.get(movements, :converted_to_credit_cents, 0) -
      Map.get(movements, :reduced_cents, 0) - Map.get(movements, :charged_back_cents, 0)
  end

  defp credit_effect(movements) do
    Map.get(movements, :issued_cents, Map.get(movements, "issued", 0)) -
      Map.get(movements, :expired_cents, Map.get(movements, "expired", 0)) -
      Map.get(movements, :consumed_cents, Map.get(movements, "consumed", 0)) -
      Map.get(movements, :revoked_cents, Map.get(movements, "revoked", 0)) -
      Map.get(movements, :absorbed_cents, Map.get(movements, "absorbed", 0))
  end

  defp applied_losses(before, after_amounts) do
    before
    |> Enum.reduce(%{}, fn {lot_id, before_amount}, losses ->
      lost = before_amount - Map.get(after_amounts, lot_id, 0)
      if lost > 0, do: Map.put(losses, lot_id, lost), else: losses
    end)
  end

  defp group_change(before, after_snapshot, group_id, field) do
    group_snapshot(after_snapshot, group_id)
    |> Map.get(field, 0)
    |> Kernel.-(Map.get(group_snapshot(before, group_id), field, 0))
  end

  defp group_property(after_snapshot, before, group_id) do
    group_snapshot(after_snapshot, group_id).property_id ||
      group_snapshot(before, group_id).property_id
  end

  defp group_snapshot(snapshot, external_group_id) do
    snapshot.groups
    |> Map.values()
    |> Enum.find(%{property_id: nil}, &(&1.group_id == external_group_id))
  end

  defp movement(_operation_id, _posting_on, _currency, _kind, _property_id, 0, _late_adjustment?),
    do: :ok

  defp movement(
         operation_id,
         posting_on,
         currency,
         kind,
         property_id,
         amount_cents,
         late_adjustment?
       ) do
    Repo.insert_all("finance_reporting_movements", [
      %{
        operation_id: operation_id,
        posting_on: posting_on,
        currency: currency,
        kind: kind,
        property_id: property_id,
        amount_cents: amount_cents,
        late_adjustment: late_adjustment?,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    :ok
  end

  defp credit_lot_event(_operation_id, _lot_id, _posting_on, 0, 0), do: :ok

  defp credit_lot_event(
         operation_id,
         lot_id,
         posting_on,
         available_delta_cents,
         applied_delta_cents
       ) do
    Repo.insert_all("finance_reporting_credit_lot_events", [
      %{
        operation_id: operation_id,
        credit_lot_id: lot_id,
        posting_on: posting_on,
        available_delta_cents: available_delta_cents,
        applied_delta_cents: applied_delta_cents,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    :ok
  end

  defp posting_date(operation, starts_on) do
    ordinary_posting_on =
      case operation_date(operation) do
        %Date{} = occurred_on ->
          if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on

        _ ->
          starts_on
      end

    case latest_period_end() do
      %Date{} = period_end_on ->
        first_open_on = Date.add(period_end_on, 1)

        if Date.compare(ordinary_posting_on, first_open_on) == :lt do
          {first_open_on, true}
        else
          {ordinary_posting_on, false}
        end

      nil ->
        {ordinary_posting_on, false}
    end
  end

  # Earlier payment-correction operations intentionally did not require this
  # field.  Keeping them valid means they post on the reporting inception when
  # no occurrence date was supplied.
  defp operation_date(%{"occurred_on" => occurred_on}) when is_binary(occurred_on) do
    case Date.from_iso8601(occurred_on) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp operation_date(_operation), do: nil

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp insert_all([], _table), do: :ok
  defp insert_all(rows, table), do: Repo.insert_all(table, rows)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
