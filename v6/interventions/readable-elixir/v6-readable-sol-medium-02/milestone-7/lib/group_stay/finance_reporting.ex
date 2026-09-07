defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Owns the durable inception snapshot, period cutoff, and classified movements for daily finance
  reports.

  Partner operations are captured inside their existing database transaction. Cash movement
  classifications are derived from property-level accounting changes, while credit-lot expiry
  positions retain the amount due to expire on a future no-operation day. Once a period closes,
  later operations are posted to its first open day and identified as late adjustments. Report
  reads are pure projections over those durable facts.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CancellationPolicy,
    GroupReservation,
    HotelCreditAllocation,
    HotelCreditLot
  }

  alias GroupStay.FinanceReporting.{
    CashOpening,
    Configuration,
    CreditExpiryPosition,
    Movement
  }

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_fields ~w(credit_issued_cents credit_expired_cents credit_consumed_cents credit_revoked_cents credit_absorbed_cents)a
  @settlement_fields ~w(refunded retained converted_to_credit)a

  @doc "Starts reporting from a snapshot of the finance state currently committed."
  def start(starts_on) do
    if Repo.exists?(Configuration) do
      {:error, :reporting_already_started}
    else
      snapshot = snapshot(starts_on)

      configuration =
        %Configuration{}
        |> Changeset.change(%{
          starts_on: starts_on,
          opening_credit_liability_cents: snapshot.credit_liability_cents
        })
        |> Repo.insert!()

      insert_cash_openings(configuration.id, snapshot.cash)
      seed_expiry_positions(snapshot.lots, starts_on)
      :ok
    end
  end

  @doc "Closes every reporting day through a strictly increasing cutoff."
  def close(period_end_on) do
    case Repo.one(from configuration in Configuration, limit: 1) do
      nil ->
        {:error, :invalid_period}

      configuration ->
        if valid_period?(configuration, period_end_on) do
          configuration
          |> Changeset.change(latest_period_end_on: period_end_on)
          |> Repo.update!()

          :ok
        else
          {:error, :invalid_period}
        end
    end
  end

  @doc "Runs an operation and, if reporting is enabled, records all of its finance effects."
  def capture(operation, apply_operation) when is_function(apply_operation, 0) do
    case Repo.one(from configuration in Configuration, limit: 1) do
      nil ->
        apply_operation.()

      configuration ->
        {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
        ordinary_posting_on = max_date(occurred_on, configuration.starts_on)
        posting_on = posting_on(ordinary_posting_on, configuration.latest_period_end_on)
        late_adjustment? = Date.after?(posting_on, ordinary_posting_on)
        before = snapshot(posting_on)
        result = apply_operation.()
        after_snapshot = snapshot(posting_on)

        record_cash_movements(
          operation,
          posting_on,
          late_adjustment?,
          before.cash,
          after_snapshot.cash
        )

        record_credit_movement(
          operation,
          result,
          posting_on,
          late_adjustment?,
          before,
          after_snapshot
        )

        update_expiry_positions(before.lots, after_snapshot.lots, posting_on)
        result
    end
  end

  @doc "Returns a report projection, or an availability error."
  def daily_report(date) do
    case Repo.one(from configuration in Configuration, limit: 1) do
      nil ->
        {:error, :report_not_available}

      configuration ->
        if Date.before?(date, configuration.starts_on),
          do: {:error, :report_not_available},
          else: {:ok, build_report(configuration, date)}
    end
  end

  defp snapshot(on) do
    groups = Repo.all(GroupReservation)

    cash =
      groups
      |> Enum.group_by(& &1.property_id)
      |> Map.new(fn {property_id, property_groups} ->
        {property_id,
         %{
           held:
             Enum.sum_by(property_groups, fn group ->
               if group.status == "active", do: group.cash_paid_cents, else: 0
             end),
           refunded: Enum.sum_by(property_groups, & &1.cash_refunded_cents),
           retained: Enum.sum_by(property_groups, & &1.cash_retained_cents),
           converted_to_credit: Enum.sum_by(property_groups, & &1.cash_converted_to_credit_cents)
         }}
      end)

    lots =
      Repo.all(HotelCreditLot)
      |> Map.new(&{&1.id, %{remaining: &1.remaining_cents, expires_on: &1.expires_on}})

    unrecovered_clawback_cents =
      Repo.one(
        from lot in HotelCreditLot,
          select: coalesce(sum(lot.unrecovered_clawback_cents), 0)
      )

    %{
      cash: cash,
      lots: lots,
      credit_liability_cents: credit_liability(on),
      unrecovered_clawback_cents: unrecovered_clawback_cents
    }
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from lot in HotelCreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in HotelCreditAllocation,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp insert_cash_openings(configuration_id, cash) do
    now = DateTime.utc_now(:second)

    rows =
      for {property_id, %{held: held}} <- cash, held != 0 do
        %{
          configuration_id: configuration_id,
          property_id: property_id,
          opening_held_cents: held,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(CashOpening, rows)
  end

  defp seed_expiry_positions(lots, starts_on) do
    Enum.each(lots, fn {lot_id, lot} ->
      if lot.remaining > 0 and not Date.before?(lot.expires_on, starts_on) do
        put_expiry_position(lot_id, lot.expires_on, lot.remaining)
      end
    end)
  end

  defp record_cash_movements(
         operation,
         posting_on,
         late_adjustment?,
         before,
         after_snapshot
       ) do
    property_ids = (Map.keys(before) ++ Map.keys(after_snapshot)) |> Enum.uniq()

    Enum.each(property_ids, fn property_id ->
      old = Map.get(before, property_id, empty_cash_snapshot())
      new = Map.get(after_snapshot, property_id, empty_cash_snapshot())
      held_delta = new.held - old.held

      values =
        case operation["type"] do
          "record_cash_payment" ->
            %{received_cents: max(held_delta, 0)}

          "transfer_deposit" ->
            %{
              transferred_in_cents: max(held_delta, 0),
              transferred_out_cents: max(-held_delta, 0)
            }

          type when type in ["cancel_group", "cancel_rooms"] ->
            settlement_deltas(old, new)

          "reduce_cash_payment" ->
            %{reduced_cents: max(-held_delta, 0)}

          "charge_back_payment" ->
            chargeback_cash_deltas(old, new, held_delta)

          _other ->
            %{}
        end

      insert_movement(
        operation["operation_id"],
        posting_on,
        property_id,
        late_adjustment?,
        values
      )
    end)
  end

  defp settlement_deltas(old, new) do
    Map.new(@settlement_fields, fn field ->
      {String.to_existing_atom("#{field}_cents"), Map.fetch!(new, field) - Map.fetch!(old, field)}
    end)
  end

  defp chargeback_cash_deltas(old, new, held_delta) do
    reclassifications = settlement_deltas(old, new)

    charged_back =
      -held_delta - reclassifications.refunded_cents - reclassifications.retained_cents -
        reclassifications.converted_to_credit_cents

    Map.put(reclassifications, :charged_back_cents, charged_back)
  end

  defp record_credit_movement(
         operation,
         result,
         posting_on,
         late_adjustment?,
         before,
         after_snapshot
       ) do
    liability_outflow =
      max(
        before.credit_liability_cents + Map.get(result, :credit_issued_cents, 0) -
          after_snapshot.credit_liability_cents,
        0
      )

    values =
      case operation["type"] do
        type when type in ["cancel_group", "cancel_rooms"] ->
          cancellation_credit_movement(
            operation,
            result,
            before,
            after_snapshot,
            liability_outflow
          )

        "charge_back_payment" ->
          %{credit_revoked_cents: liability_outflow}

        _other ->
          %{}
      end

    insert_movement(operation["operation_id"], posting_on, nil, late_adjustment?, values)
  end

  defp cancellation_credit_movement(
         operation,
         result,
         before,
         after_snapshot,
         liability_outflow
       ) do
    issued = Map.get(result, :credit_issued_cents, 0)

    group = Repo.get!(GroupReservation, result.group_id)
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

    if not CancellationPolicy.refundable?(group, occurred_on) do
      %{credit_issued_cents: issued, credit_consumed_cents: liability_outflow}
    else
      absorbed =
        min(
          liability_outflow,
          max(before.unrecovered_clawback_cents - after_snapshot.unrecovered_clawback_cents, 0)
        )

      %{
        credit_issued_cents: issued,
        credit_absorbed_cents: absorbed,
        credit_expired_cents: liability_outflow - absorbed
      }
    end
  end

  defp update_expiry_positions(before, after_snapshot, posting_on) do
    lot_ids = (Map.keys(before) ++ Map.keys(after_snapshot)) |> Enum.uniq()

    Enum.each(lot_ids, fn lot_id ->
      old = Map.get(before, lot_id, %{remaining: 0, expires_on: nil})
      new = Map.get(after_snapshot, lot_id, old)
      delta = new.remaining - old.remaining

      if delta != 0 and not Date.before?(new.expires_on, posting_on) do
        adjust_expiry_position(lot_id, new.expires_on, delta)
      end
    end)
  end

  defp adjust_expiry_position(lot_id, expires_on, delta) do
    case Repo.get_by(CreditExpiryPosition, lot_id: lot_id) do
      nil ->
        put_expiry_position(lot_id, expires_on, max(delta, 0))

      position ->
        position
        |> Changeset.change(amount_cents: position.amount_cents + delta)
        |> Repo.update!()
    end
  end

  defp put_expiry_position(_lot_id, _expires_on, 0), do: :ok

  defp put_expiry_position(lot_id, expires_on, amount) do
    %CreditExpiryPosition{}
    |> Changeset.change(lot_id: lot_id, expires_on: expires_on, amount_cents: amount)
    |> Repo.insert!()
  end

  defp insert_movement(_operation_id, _posting_on, _property_id, _late_adjustment?, values)
       when map_size(values) == 0,
       do: :ok

  defp insert_movement(operation_id, posting_on, property_id, late_adjustment?, values) do
    if Enum.any?(values, fn {_field, amount} -> amount != 0 end) do
      %Movement{}
      |> Changeset.change(
        values
        |> Map.put(:operation_id, operation_id)
        |> Map.put(:posting_on, posting_on)
        |> Map.put(:property_id, property_id)
        |> Map.put(:late_adjustment, late_adjustment?)
      )
      |> Repo.insert!()
    else
      :ok
    end
  end

  defp build_report(configuration, date) do
    openings = Repo.all(CashOpening) |> Map.new(&{&1.property_id, &1.opening_held_cents})
    movements = Repo.all(from movement in Movement, where: movement.posting_on <= ^date)

    cash =
      (Map.keys(openings) ++ Enum.flat_map(movements, &[&1.property_id]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&cash_report_entry(&1, date, openings, movements))
      |> Enum.reject(&zero_cash_entry?/1)

    ordinary_credit_movements = credit_totals_for_date(movements, date, false)
    late_credit_movements = credit_totals_for_date(movements, date, true)

    opening_credit =
      configuration.opening_credit_liability_cents +
        credit_net(movements, configuration.starts_on, Date.add(date, -1))

    opening_credit = opening_credit - expiry_total(configuration.starts_on, Date.add(date, -1))

    closing_credit =
      opening_credit + credit_net(ordinary_credit_movements) + credit_net(late_credit_movements) -
        expiry_total(date, date)

    ordinary_credit_movements =
      ordinary_credit_movements
      |> Map.update!(:expired_cents, &(&1 + expiry_total(date, date)))

    %{
      date: date,
      status: report_status(configuration, date),
      cash: cash,
      credit: %{
        opening_liability_cents: opening_credit,
        movements: ordinary_credit_movements,
        closing_liability_cents: closing_credit
      },
      late_adjustments: %{
        cash: late_cash_entries(movements, date),
        credit: late_credit_movements
      }
    }
  end

  defp cash_report_entry(property_id, date, openings, all_movements) do
    property_movements = Enum.filter(all_movements, &(&1.property_id == property_id))

    opening =
      Map.get(openings, property_id, 0) + cash_net(property_movements, nil, Date.add(date, -1))

    ordinary_movements = cash_totals_for_date(property_movements, date, false)
    late_movements = cash_totals_for_date(property_movements, date, true)

    %{
      property_id: property_id,
      opening_held_cents: opening,
      movements: ordinary_movements,
      closing_held_cents: opening + cash_net(ordinary_movements) + cash_net(late_movements)
    }
  end

  defp zero_cash_entry?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(entry.movements, fn {_field, amount} -> amount == 0 end)
  end

  defp cash_totals_for_date(movements, date, late_adjustment?) do
    movements
    |> Enum.filter(&(&1.posting_on == date and &1.late_adjustment == late_adjustment?))
    |> sum_fields(@cash_fields)
  end

  defp credit_totals_for_date(movements, date, late_adjustment?) do
    totals =
      movements
      |> Enum.filter(
        &(&1.posting_on == date and is_nil(&1.property_id) and
            &1.late_adjustment == late_adjustment?)
      )
      |> sum_fields(@credit_fields)

    %{
      issued_cents: totals.credit_issued_cents,
      expired_cents: totals.credit_expired_cents,
      consumed_cents: totals.credit_consumed_cents,
      revoked_cents: totals.credit_revoked_cents,
      absorbed_cents: totals.credit_absorbed_cents
    }
  end

  defp late_cash_entries(movements, date) do
    movements
    |> Enum.filter(&(&1.posting_on == date and &1.late_adjustment and not is_nil(&1.property_id)))
    |> Enum.group_by(& &1.property_id)
    |> Enum.map(fn {property_id, property_movements} ->
      %{property_id: property_id, movements: sum_fields(property_movements, @cash_fields)}
    end)
    |> Enum.reject(fn entry ->
      Enum.all?(entry.movements, fn {_field, amount} -> amount == 0 end)
    end)
    |> Enum.sort_by(& &1.property_id)
  end

  defp sum_fields(rows, fields) do
    Map.new(fields, fn field -> {field, Enum.sum_by(rows, &Map.fetch!(&1, field))} end)
  end

  defp cash_net(movements, from, through) when is_list(movements) do
    movements
    |> Enum.filter(fn movement ->
      (is_nil(from) or not Date.before?(movement.posting_on, from)) and
        not Date.after?(movement.posting_on, through)
    end)
    |> sum_fields(@cash_fields)
    |> cash_net()
  end

  defp cash_net(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents -
      movements.charged_back_cents
  end

  defp credit_net(movements, from, through) when is_list(movements) do
    movements
    |> Enum.filter(fn movement ->
      is_nil(movement.property_id) and not Date.before?(movement.posting_on, from) and
        not Date.after?(movement.posting_on, through)
    end)
    |> sum_fields(@credit_fields)
    |> then(fn totals ->
      totals.credit_issued_cents - totals.credit_expired_cents - totals.credit_consumed_cents -
        totals.credit_revoked_cents - totals.credit_absorbed_cents
    end)
  end

  defp credit_net(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp expiry_total(from, through) do
    if Date.before?(through, from) do
      0
    else
      Repo.all(CreditExpiryPosition)
      |> Enum.filter(fn position ->
        posting_on = Date.add(position.expires_on, 1)
        not Date.before?(posting_on, from) and not Date.after?(posting_on, through)
      end)
      |> Enum.sum_by(& &1.amount_cents)
    end
  end

  defp empty_cash_snapshot,
    do: %{held: 0, refunded: 0, retained: 0, converted_to_credit: 0}

  defp valid_period?(configuration, period_end_on) do
    not Date.before?(period_end_on, configuration.starts_on) and
      (is_nil(configuration.latest_period_end_on) or
         Date.after?(period_end_on, configuration.latest_period_end_on))
  end

  defp posting_on(ordinary_posting_on, nil), do: ordinary_posting_on

  defp posting_on(ordinary_posting_on, latest_period_end_on) do
    max_date(ordinary_posting_on, Date.add(latest_period_end_on, 1))
  end

  defp report_status(%Configuration{latest_period_end_on: nil}, _date), do: "open"

  defp report_status(configuration, date) do
    if Date.after?(date, configuration.latest_period_end_on), do: "open", else: "closed"
  end

  defp max_date(left, right), do: if(Date.before?(left, right), do: right, else: left)
end
