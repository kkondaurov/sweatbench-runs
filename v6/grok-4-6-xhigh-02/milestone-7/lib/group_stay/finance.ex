defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Finance.ClosedReport
  alias GroupStay.Finance.Event
  alias GroupStay.Finance.LotOpening
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups.CashSettlement
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @cash_classifications ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  @credit_classifications ~w(issued expired consumed revoked absorbed)

  def parse_date(%Date{} = date), do: {:ok, date}

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def parse_date(_), do: :error

  def started? do
    Repo.exists?(from(r in Reporting))
  end

  def get_reporting do
    Repo.one(from r in Reporting, limit: 1)
  end

  def posting_date(%Date{} = occurred_on) do
    case posting_meta(occurred_on) do
      %{posted_on: posted_on} -> posted_on
      _ -> nil
    end
  end

  def posting_date(_), do: nil

  def start(%Date{} = starts_on, operation_id) when is_binary(operation_id) do
    if started?() do
      {:error, :reporting_already_started}
    else
      persist_start(starts_on, operation_id)
    end
  end

  def close(%Date{} = period_end_on) do
    case get_reporting() do
      nil ->
        {:error, :invalid_period}

      %Reporting{} = reporting ->
        if valid_close?(reporting, period_end_on) do
          persist_close(reporting, period_end_on)
        else
          {:error, :invalid_period}
        end
    end
  end

  def daily_report(date_value) do
    case parse_date(date_value) do
      :error ->
        {:error, :invalid_reporting_date}

      {:ok, date} ->
        case get_reporting() do
          nil ->
            {:error, :report_not_available}

          %Reporting{} = reporting ->
            cond do
              Date.compare(date, reporting.starts_on) == :lt ->
                {:error, :report_not_available}

              snapshot = get_closed_report(date) ->
                {:ok, snapshot.data}

              true ->
                {:ok, build_report(reporting, date)}
            end
        end
    end
  end

  def record_cash(_occurred_on, _operation_id, _property_id, _classification, amount)
      when amount == 0,
      do: :ok

  def record_cash(occurred_on, operation_id, property_id, classification, amount)
      when is_binary(property_id) and is_integer(amount) do
    with %{posted_on: posted_on, late_adjustment: late?} <- posting_meta(occurred_on) do
      insert_event!(%{
        posted_on: posted_on,
        late_adjustment: late?,
        operation_id: operation_id,
        property_id: property_id,
        kind: "cash",
        classification: classification,
        amount_cents: amount
      })
    end

    :ok
  end

  def record_cash(_occurred_on, _operation_id, _property_id, _classification, _amount), do: :ok

  def record_cash_by_property(occurred_on, operation_id, classification, by_property)
      when is_map(by_property) do
    Enum.each(by_property, fn {property_id, amount} ->
      record_cash(occurred_on, operation_id, property_id, classification, amount)
    end)
  end

  def record_transfer(occurred_on, operation_id, source_property_id, dest_property_id, amount)
      when is_integer(amount) and amount > 0 do
    record_cash(occurred_on, operation_id, source_property_id, "transferred_out", amount)
    record_cash(occurred_on, operation_id, dest_property_id, "transferred_in", amount)
  end

  def record_transfer(_occurred_on, _operation_id, _source, _dest, _amount), do: :ok

  def record_credit(occurred_on, operation_id, classification, amount, attrs \\ %{})

  def record_credit(_occurred_on, _operation_id, _classification, amount, _attrs)
      when amount == 0,
      do: :ok

  def record_credit(occurred_on, operation_id, classification, amount, attrs)
      when is_integer(amount) do
    with %{posted_on: posted_on, late_adjustment: late?} <- posting_meta(occurred_on) do
      insert_event!(
        Map.merge(
          %{
            posted_on: posted_on,
            late_adjustment: late?,
            operation_id: operation_id,
            kind: "credit",
            classification: classification,
            amount_cents: amount
          },
          attrs
        )
      )
    end

    :ok
  end

  def record_issued(occurred_on, operation_id, amount, expires_on)
      when is_integer(amount) and amount > 0 do
    record_credit(occurred_on, operation_id, "issued", amount, %{
      lot_source_operation_id: operation_id,
      expires_on: expires_on
    })
  end

  def record_issued(_occurred_on, _operation_id, _amount, _expires_on), do: :ok

  def record_applied(occurred_on, operation_id, takes) when is_list(takes) do
    Enum.each(takes, fn {lot, amount} ->
      record_remaining_delta(occurred_on, operation_id, lot, -amount)
    end)
  end

  def record_restore_effects(occurred_on, operation_id, effects) when is_list(effects) do
    Enum.each(effects, fn effect ->
      record_remaining_delta(occurred_on, operation_id, effect.lot, effect.restored_cents)
      record_credit(occurred_on, operation_id, "absorbed", effect.absorbed_cents)
      record_credit(occurred_on, operation_id, "expired", effect.expired_cents)
    end)
  end

  def record_remaining_delta(_occurred_on, _operation_id, _lot, amount) when amount == 0, do: :ok

  def record_remaining_delta(occurred_on, operation_id, lot, amount) when is_integer(amount) do
    with %{posted_on: posted_on, late_adjustment: late?} <- posting_meta(occurred_on) do
      insert_event!(%{
        posted_on: posted_on,
        late_adjustment: late?,
        operation_id: operation_id,
        kind: "lot",
        classification: "remaining_delta",
        amount_cents: amount,
        lot_source_operation_id: lot.source_operation_id,
        expires_on: lot.expires_on
      })
    end

    :ok
  end

  def add_settlement!(_payment_operation_id, _property_id, _disposition, amount)
      when amount <= 0,
      do: :ok

  def add_settlement!(payment_operation_id, property_id, disposition, amount)
      when is_binary(payment_operation_id) and is_binary(property_id) and amount > 0 do
    case Repo.get_by(CashSettlement,
           payment_operation_id: payment_operation_id,
           property_id: property_id,
           disposition: to_string(disposition)
         ) do
      nil ->
        %CashSettlement{}
        |> CashSettlement.changeset(%{
          payment_operation_id: payment_operation_id,
          property_id: property_id,
          disposition: to_string(disposition),
          amount_cents: amount
        })
        |> Repo.insert!()

      settlement ->
        settlement
        |> CashSettlement.changeset(%{amount_cents: settlement.amount_cents + amount})
        |> Repo.update!()
    end

    :ok
  end

  def add_settlement!(_payment_operation_id, _property_id, _disposition, _amount), do: :ok

  def take_settlements!(payment_operation_id, %{} = payment, fallback_property_id)
      when is_binary(payment_operation_id) do
    rows =
      from(s in CashSettlement, where: s.payment_operation_id == ^payment_operation_id)
      |> Repo.all()

    if rows == [] do
      fallback_settlements(payment, fallback_property_id)
    else
      Enum.each(rows, &Repo.delete!/1)
      Enum.map(rows, &{&1.property_id, &1.disposition, &1.amount_cents})
    end
  end

  defp fallback_settlements(payment, fallback_property_id) do
    [
      {fallback_property_id, "refunded", payment.refunded_cents},
      {fallback_property_id, "retained", payment.retained_cents},
      {fallback_property_id, "converted", payment.converted_to_credit_cents}
    ]
    |> Enum.reject(fn {property_id, _disposition, amount} ->
      is_nil(property_id) or amount <= 0
    end)
  end

  defp persist_close(%Reporting{} = reporting, period_end_on) do
    from = first_open_on(reporting)

    reporting =
      reporting
      |> Reporting.changeset(%{closed_through: period_end_on})
      |> Repo.update!()

    Enum.each(Date.range(from, period_end_on), fn date ->
      publish_report!(reporting, date)
    end)

    {:ok, period_end_on}
  end

  defp publish_report!(reporting, date) do
    case get_closed_report(date) do
      nil ->
        data =
          reporting
          |> build_report(date)
          |> Jason.encode!()
          |> Jason.decode!()

        %ClosedReport{}
        |> ClosedReport.changeset(%{date: date, data: data})
        |> Repo.insert!()

      _existing ->
        :ok
    end
  end

  defp get_closed_report(%Date{} = date) do
    Repo.get(ClosedReport, date)
  end

  defp valid_close?(
         %Reporting{starts_on: starts_on, closed_through: closed_through},
         period_end_on
       ) do
    Date.compare(period_end_on, starts_on) != :lt and
      (is_nil(closed_through) or Date.compare(period_end_on, closed_through) == :gt)
  end

  defp first_open_on(%Reporting{starts_on: starts_on, closed_through: nil}), do: starts_on
  defp first_open_on(%Reporting{closed_through: closed_through}), do: Date.add(closed_through, 1)

  defp posting_meta(%Date{} = occurred_on) do
    case get_reporting() do
      nil ->
        nil

      %Reporting{} = reporting ->
        natural = later_date(occurred_on, reporting.starts_on)
        posted_on = later_date(natural, first_open_on(reporting))

        %{
          posted_on: posted_on,
          late_adjustment: Date.compare(posted_on, natural) == :gt
        }
    end
  end

  defp posting_meta(_), do: nil

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp persist_start(starts_on, operation_id) do
    opening_cash = current_held_by_property()
    opening_liability = Credit.liability_cents(starts_on)

    result =
      %Reporting{}
      |> Reporting.changeset(%{
        id: 1,
        starts_on: starts_on,
        start_operation_id: operation_id,
        opening_liability_cents: opening_liability,
        opening_cash: opening_cash
      })
      |> Repo.insert()

    case result do
      {:ok, reporting} ->
        snapshot_lots!(starts_on)
        {:ok, reporting.starts_on}

      {:error, changeset} ->
        if unique_start_error?(changeset) do
          {:error, :reporting_already_started}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp snapshot_lots!(starts_on) do
    from(l in CreditLot,
      where: l.remaining_cents > 0 and l.expires_on >= ^starts_on
    )
    |> Repo.all()
    |> Enum.each(fn lot ->
      %LotOpening{}
      |> LotOpening.changeset(%{
        source_operation_id: lot.source_operation_id,
        expires_on: lot.expires_on,
        remaining_cents: lot.remaining_cents
      })
      |> Repo.insert!()
    end)
  end

  defp current_held_by_property do
    from(r in Room,
      join: g in Group,
      on: r.group_id == g.id,
      where: r.status == "active" and g.status == "active",
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(r.cash_paid_cents), 0)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {property_id, amount}, acc ->
      if amount > 0 do
        Map.put(acc, property_id, amount)
      else
        acc
      end
    end)
  end

  defp insert_event!(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert!()
  end

  defp build_report(reporting, date) do
    events = from(e in Event, order_by: [asc: e.id]) |> Repo.all()
    openings = Repo.all(LotOpening)
    {cash, late_cash} = build_cash(reporting, events, date)
    {credit, late_credit} = build_credit(reporting, events, openings, date)

    %{
      date: date,
      status: report_status(reporting, date),
      cash: cash,
      credit: credit,
      late_adjustments: %{
        cash: late_cash,
        credit: late_credit
      }
    }
  end

  defp report_status(%Reporting{closed_through: nil}, _date), do: "open"

  defp report_status(%Reporting{closed_through: closed_through}, date) do
    if Date.compare(date, closed_through) == :gt, do: "open", else: "closed"
  end

  defp build_cash(reporting, events, date) do
    opening_map = stringify_keys(reporting.opening_cash || %{})
    cash_events = Enum.filter(events, &(&1.kind == "cash"))

    properties =
      (Map.keys(opening_map) ++ Enum.map(cash_events, & &1.property_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    entries_and_late =
      Enum.map(properties, fn property_id ->
        prior =
          Enum.filter(cash_events, fn event ->
            event.property_id == property_id and Date.compare(event.posted_on, date) == :lt
          end)

        today =
          Enum.filter(cash_events, fn event ->
            event.property_id == property_id and Date.compare(event.posted_on, date) == :eq
          end)

        ordinary_today = Enum.reject(today, &late?/1)
        late_today = Enum.filter(today, &late?/1)
        ordinary = sum_cash(ordinary_today)
        late = sum_cash(late_today)
        opening = apply_cash(as_int(Map.get(opening_map, property_id, 0)), sum_cash(prior))
        closing = apply_cash(opening, add_movements(ordinary, late))

        entry =
          if zero_cash?(opening, closing, ordinary) and zero_movements?(late) do
            nil
          else
            %{
              property_id: property_id,
              opening_held_cents: opening,
              movements: ordinary,
              closing_held_cents: closing
            }
          end

        late_entry =
          if zero_movements?(late) do
            nil
          else
            %{property_id: property_id, movements: late}
          end

        {entry, late_entry}
      end)

    cash = Enum.flat_map(entries_and_late, fn {entry, _} -> List.wrap(entry) end)
    late_cash = Enum.flat_map(entries_and_late, fn {_, late} -> List.wrap(late) end)
    {cash, late_cash}
  end

  defp build_credit(reporting, events, openings, date) do
    credit_events = Enum.filter(events, &(&1.kind == "credit"))

    {ordinary_expiries, late_expiries} =
      lot_expiries(reporting.starts_on, date, openings, events)

    prior_events = Enum.filter(credit_events, &(Date.compare(&1.posted_on, date) == :lt))
    today_events = Enum.filter(credit_events, &(Date.compare(&1.posted_on, date) == :eq))
    ordinary_today = Enum.reject(today_events, &late?/1)
    late_today = Enum.filter(today_events, &late?/1)

    prior_auto = expiry_before(ordinary_expiries, date) + expiry_before(late_expiries, date)

    ordinary_movements =
      add_expired(sum_credit(ordinary_today), Map.get(ordinary_expiries, date, 0))

    late_movements = add_expired(sum_credit(late_today), Map.get(late_expiries, date, 0))
    prior_movements = add_expired(sum_credit(prior_events), prior_auto)
    opening = apply_credit(reporting.opening_liability_cents, prior_movements)
    closing = apply_credit(opening, add_movements(ordinary_movements, late_movements))

    credit = %{
      opening_liability_cents: opening,
      movements: ordinary_movements,
      closing_liability_cents: closing
    }

    {credit, late_movements}
  end

  defp lot_expiries(starts_on, through_date, openings, events) do
    lots = collect_lots(openings, events)

    Enum.reduce(lots, {%{}, %{}}, fn lot, {ordinary, late} ->
      add_lot_expiries(lot, starts_on, through_date, openings, events, ordinary, late)
    end)
  end

  defp add_lot_expiries(lot, starts_on, through_date, openings, events, ordinary, late) do
    natural = Date.add(lot.expires_on, 1)
    remaining = remaining_before(lot, openings, events, starts_on)

    event_dates =
      events
      |> Enum.filter(fn event ->
        event.lot_source_operation_id == lot.source_operation_id and remaining_effect(event) != 0
      end)
      |> Enum.group_by(& &1.posted_on)

    dates =
      [natural | Map.keys(event_dates)]
      |> Enum.uniq()
      |> Enum.filter(&(Date.compare(&1, through_date) != :gt))
      |> Enum.sort(Date)

    {ordinary, late, _remaining} =
      Enum.reduce(dates, {ordinary, late, remaining}, fn date, {ordinary, late, remaining} ->
        date_events = Map.get(event_dates, date, [])

        remaining =
          remaining +
            Enum.reduce(date_events, 0, fn event, acc -> acc + remaining_effect(event) end)

        cond do
          remaining <= 0 ->
            {ordinary, late, remaining}

          Date.compare(date, lot.expires_on) != :gt ->
            {ordinary, late, remaining}

          Date.compare(date, starts_on) == :lt ->
            {ordinary, late, remaining}

          Date.compare(date, natural) == :eq ->
            {add_amount(ordinary, date, remaining), late, 0}

          Enum.any?(date_events, &late?/1) ->
            {ordinary, add_amount(late, date, remaining), 0}

          true ->
            {add_amount(ordinary, date, remaining), late, 0}
        end
      end)

    {ordinary, late}
  end

  defp add_amount(map, date, amount) do
    Map.update(map, date, amount, &(&1 + amount))
  end

  defp collect_lots(openings, events) do
    from_openings =
      Map.new(openings, fn opening ->
        {opening.source_operation_id, opening.expires_on}
      end)

    from_events =
      events
      |> Enum.filter(&(not is_nil(&1.lot_source_operation_id) and not is_nil(&1.expires_on)))
      |> Enum.reduce(from_openings, fn event, acc ->
        Map.put_new(acc, event.lot_source_operation_id, event.expires_on)
      end)

    Enum.map(from_events, fn {source_operation_id, expires_on} ->
      %{source_operation_id: source_operation_id, expires_on: expires_on}
    end)
  end

  defp remaining_before(lot, openings, events, before_date) do
    opening =
      Enum.find_value(openings, 0, fn opening ->
        if opening.source_operation_id == lot.source_operation_id do
          opening.remaining_cents
        end
      end)

    Enum.reduce(events, opening, fn event, remaining ->
      if event.lot_source_operation_id == lot.source_operation_id and
           Date.compare(event.posted_on, before_date) == :lt do
        remaining + remaining_effect(event)
      else
        remaining
      end
    end)
  end

  defp remaining_effect(%Event{kind: "credit", classification: "issued", amount_cents: amount}),
    do: amount

  defp remaining_effect(%Event{kind: "credit", classification: "revoked", amount_cents: amount}),
    do: -amount

  defp remaining_effect(%Event{
         kind: "lot",
         classification: "remaining_delta",
         amount_cents: amount
       }),
       do: amount

  defp remaining_effect(_), do: 0

  defp sum_cash(events) do
    Enum.reduce(events, zero_cash_movements(), fn event, acc ->
      key = cash_key(event.classification)

      if key do
        Map.update!(acc, key, &(&1 + event.amount_cents))
      else
        acc
      end
    end)
  end

  defp sum_credit(events) do
    Enum.reduce(events, zero_credit_movements(), fn event, acc ->
      key = credit_key(event.classification)

      if key do
        Map.update!(acc, key, &(&1 + event.amount_cents))
      else
        acc
      end
    end)
  end

  defp add_expired(movements, extra) do
    Map.update!(movements, :expired_cents, &(&1 + extra))
  end

  defp apply_cash(opening, movements) do
    opening + movements.received_cents + movements.transferred_in_cents -
      movements.transferred_out_cents - movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents -
      movements.charged_back_cents
  end

  defp apply_credit(opening, movements) do
    opening + movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp zero_cash?(opening, closing, movements) do
    opening == 0 and closing == 0 and zero_movements?(movements)
  end

  defp zero_movements?(movements) do
    Enum.all?(movements, fn {_k, v} -> v == 0 end)
  end

  defp late?(%{late_adjustment: true}), do: true
  defp late?(_), do: false

  defp add_movements(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp zero_cash_movements do
    %{
      received_cents: 0,
      transferred_in_cents: 0,
      transferred_out_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }
  end

  defp zero_credit_movements do
    %{
      issued_cents: 0,
      expired_cents: 0,
      consumed_cents: 0,
      revoked_cents: 0,
      absorbed_cents: 0
    }
  end

  defp cash_key(classification) when classification in @cash_classifications do
    String.to_existing_atom(classification <> "_cents")
  end

  defp cash_key("converted_to_credit"), do: :converted_to_credit_cents
  defp cash_key(_), do: nil

  defp credit_key(classification) when classification in @credit_classifications do
    String.to_existing_atom(classification <> "_cents")
  end

  defp credit_key(_), do: nil

  defp expiry_before(expiries, date) do
    expiries
    |> Enum.reduce(0, fn {expiry_date, amount}, acc ->
      if Date.compare(expiry_date, date) == :lt, do: acc + amount, else: acc
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), as_int(value)} end)
  end

  defp as_int(value) when is_integer(value), do: value
  defp as_int(value) when is_float(value), do: trunc(value)
  defp as_int(value) when is_binary(value), do: String.to_integer(value)
  defp as_int(_), do: 0

  defp unique_start_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {field, {_, opts}} when field in [:id, :start_operation_id] ->
        opts[:constraint] in [:unique, :primary_key]

      _ ->
        false
    end)
  end
end
