defmodule GroupStay.Finance do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.FinanceEvent
  alias GroupStay.Groups.FinanceReporting

  @cash_keys %{
    "received" => :received_cents,
    "transferred_in" => :transferred_in_cents,
    "transferred_out" => :transferred_out_cents,
    "refunded" => :refunded_cents,
    "retained" => :retained_cents,
    "converted_to_credit" => :converted_to_credit_cents,
    "reduced" => :reduced_cents,
    "charged_back" => :charged_back_cents
  }

  @credit_keys %{
    "issued" => :issued_cents,
    "expired" => :expired_cents,
    "consumed" => :consumed_cents,
    "revoked" => :revoked_cents,
    "absorbed" => :absorbed_cents
  }

  def started?, do: get_config() != nil

  def persist_start(starts_on, operation_id, opening_cash, opening_credit, opening_lots) do
    %FinanceReporting{}
    |> FinanceReporting.changeset(%{
      starts_on: starts_on,
      start_operation_id: operation_id,
      opening_credit_liability_cents: opening_credit,
      opening_cash: opening_cash,
      opening_lots: opening_lots,
      singleton: 1
    })
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        if unique_violation?(changeset) do
          {:error, :already_started}
        else
          {:error, changeset}
        end
    end
  end

  def daily_report(value) do
    case parse_date(value) do
      {:ok, date} -> report_for(date)
      _ -> {:error, :invalid_date}
    end
  end

  def cash(_property_id, _class, 0, _occurred_on, _operation_id), do: :ok

  def cash(property_id, class, amount, occurred_on, operation_id)
      when is_binary(property_id) and is_integer(amount) do
    insert_event(%{
      kind: "cash",
      classification: class,
      property_id: property_id,
      amount_cents: amount,
      occurred_on: occurred_on,
      operation_id: operation_id
    })
  end

  def cash(_property_id, _class, _amount, _occurred_on, _operation_id), do: :ok

  def credit(class, amount, occurred_on, operation_id, opts \\ [])

  def credit(_class, 0, _occurred_on, _operation_id, _opts), do: :ok

  def credit(class, amount, occurred_on, operation_id, opts) when is_integer(amount) do
    insert_event(%{
      kind: "credit",
      classification: class,
      amount_cents: amount,
      occurred_on: occurred_on,
      operation_id: operation_id,
      lot_source_operation_id: Keyword.get(opts, :lot_source),
      lot_expires_on: Keyword.get(opts, :expires_on)
    })
  end

  def lot_delta(_source, _expires_on, 0, _occurred_on, _operation_id), do: :ok

  def lot_delta(source, expires_on, amount, occurred_on, operation_id) when is_integer(amount) do
    insert_event(%{
      kind: "lot",
      classification: "remaining_delta",
      amount_cents: amount,
      occurred_on: occurred_on,
      operation_id: operation_id,
      lot_source_operation_id: source,
      lot_expires_on: expires_on
    })
  end

  def available_on_posting?(expires_on, occurred_on) do
    case get_config() do
      nil ->
        false

      config ->
        posting = posting_date(occurred_on, config.starts_on)
        Date.compare(expires_on, posting) != :lt
    end
  end

  defp report_for(date) do
    case get_config() do
      nil ->
        {:error, :not_available}

      config ->
        if Date.compare(date, config.starts_on) == :lt do
          {:error, :not_available}
        else
          {:ok, build_report(config, date)}
        end
    end
  end

  defp build_report(config, date) do
    events =
      from(e in FinanceEvent,
        where: e.posting_date <= ^date,
        order_by: [asc: e.posting_date, asc: e.id]
      )
      |> Repo.all()

    {expired_today, expired_through} = replay_expiry(config, events, date)

    {cash_day, cash_before} = split_cash(events, date)
    {credit_day, credit_through} = split_credit(events, date)

    credit_day = Map.update!(credit_day, :expired_cents, &(&1 + expired_today))
    credit_through = Map.update!(credit_through, :expired_cents, &(&1 + expired_through))

    opening_credit = config.opening_credit_liability_cents || 0
    credit_prior = subtract_credit(credit_through, credit_day)
    opening_on_date = apply_credit(opening_credit, credit_prior)
    closing_credit = apply_credit(opening_credit, credit_through)

    opening_cash = stringify_keys(config.opening_cash || %{})

    properties =
      opening_cash
      |> Map.keys()
      |> Enum.concat(Map.keys(cash_day))
      |> Enum.concat(Map.keys(cash_before))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        inception = as_int(Map.get(opening_cash, property_id, 0))
        before = Map.get(cash_before, property_id, empty_cash())
        day = Map.get(cash_day, property_id, empty_cash())
        opening = apply_cash(inception, before)
        closing = apply_cash(opening, day)

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: day,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(&zero_cash?/1)

    %{
      date: date,
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening_on_date,
        movements: credit_day,
        closing_liability_cents: closing_credit
      }
    }
  end

  defp replay_expiry(config, events, date) do
    lots =
      (config.opening_lots || [])
      |> Enum.reduce(%{}, fn lot, acc ->
        source = lot_source(lot)
        remaining = as_int(lot_remaining(lot))
        expires_on = lot_expires(lot)

        if is_binary(source) and remaining > 0 and expires_on != nil do
          Map.put(acc, source, %{remaining: remaining, expires_on: expires_on})
        else
          acc
        end
      end)

    by_date = Enum.group_by(events, & &1.posting_date)

    Date.range(config.starts_on, date)
    |> Enum.reduce({lots, 0, 0}, fn day, {lots, expired_today, expired_through} ->
      {lots, start_expired} = expire_due(lots, day)
      lots = apply_day_lot_events(lots, Map.get(by_date, day, []))
      {lots, end_expired} = expire_due(lots, day)
      day_expired = start_expired + end_expired
      expired_through = expired_through + day_expired

      expired_today =
        if Date.compare(day, date) == :eq do
          day_expired
        else
          expired_today
        end

      {lots, expired_today, expired_through}
    end)
    |> then(fn {_lots, expired_today, expired_through} -> {expired_today, expired_through} end)
  end

  defp expire_due(lots, day) do
    Enum.reduce(lots, {%{}, 0}, fn {source, lot}, {acc, expired} ->
      if lot.remaining > 0 and Date.compare(lot.expires_on, day) == :lt do
        {Map.put(acc, source, %{lot | remaining: 0}), expired + lot.remaining}
      else
        {Map.put(acc, source, lot), expired}
      end
    end)
  end

  defp apply_day_lot_events(lots, events) do
    Enum.reduce(events, lots, fn event, lots ->
      cond do
        event.kind == "credit" and event.classification == "issued" ->
          source = event.lot_source_operation_id
          expires_on = event.lot_expires_on

          if is_binary(source) do
            Map.update(
              lots,
              source,
              %{remaining: event.amount_cents, expires_on: expires_on},
              fn lot -> %{lot | remaining: lot.remaining + event.amount_cents} end
            )
          else
            lots
          end

        event.kind == "credit" and event.classification == "revoked" ->
          source = event.lot_source_operation_id

          if is_binary(source) and Map.has_key?(lots, source) do
            Map.update!(lots, source, fn lot ->
              %{lot | remaining: max(lot.remaining - event.amount_cents, 0)}
            end)
          else
            lots
          end

        event.kind == "lot" and event.classification == "remaining_delta" ->
          source = event.lot_source_operation_id

          if is_binary(source) do
            Map.update(
              lots,
              source,
              %{remaining: max(event.amount_cents, 0), expires_on: event.lot_expires_on},
              fn lot -> %{lot | remaining: lot.remaining + event.amount_cents} end
            )
          else
            lots
          end

        true ->
          lots
      end
    end)
  end

  defp split_cash(events, date) do
    Enum.reduce(events, {%{}, %{}}, fn event, {day, before} ->
      if event.kind == "cash" do
        key = Map.get(@cash_keys, event.classification)
        property_id = event.property_id

        if key && is_binary(property_id) do
          if Date.compare(event.posting_date, date) == :eq do
            {add_cash(day, property_id, key, event.amount_cents), before}
          else
            {day, add_cash(before, property_id, key, event.amount_cents)}
          end
        else
          {day, before}
        end
      else
        {day, before}
      end
    end)
  end

  defp split_credit(events, date) do
    Enum.reduce(events, {empty_credit(), empty_credit()}, fn event, {day, through} ->
      if event.kind == "credit" do
        key = Map.get(@credit_keys, event.classification)

        if key do
          through = Map.update!(through, key, &(&1 + event.amount_cents))

          if Date.compare(event.posting_date, date) == :eq do
            {Map.update!(day, key, &(&1 + event.amount_cents)), through}
          else
            {day, through}
          end
        else
          {day, through}
        end
      else
        {day, through}
      end
    end)
  end

  defp add_cash(map, property_id, key, amount) do
    current = Map.get(map, property_id, empty_cash())
    Map.put(map, property_id, Map.update!(current, key, &(&1 + amount)))
  end

  defp apply_cash(opening, mov) do
    opening + mov.received_cents + mov.transferred_in_cents - mov.transferred_out_cents -
      mov.refunded_cents - mov.retained_cents - mov.converted_to_credit_cents -
      mov.reduced_cents - mov.charged_back_cents
  end

  defp apply_credit(opening, mov) do
    opening + mov.issued_cents - mov.expired_cents - mov.consumed_cents - mov.revoked_cents -
      mov.absorbed_cents
  end

  defp subtract_credit(through, day) do
    %{
      issued_cents: through.issued_cents - day.issued_cents,
      expired_cents: through.expired_cents - day.expired_cents,
      consumed_cents: through.consumed_cents - day.consumed_cents,
      revoked_cents: through.revoked_cents - day.revoked_cents,
      absorbed_cents: through.absorbed_cents - day.absorbed_cents
    }
  end

  defp zero_cash?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(entry.movements, fn {_k, v} -> v == 0 end)
  end

  defp empty_cash do
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

  defp empty_credit do
    %{
      issued_cents: 0,
      expired_cents: 0,
      consumed_cents: 0,
      revoked_cents: 0,
      absorbed_cents: 0
    }
  end

  defp insert_event(attrs) do
    case get_config() do
      nil ->
        :ok

      config ->
        posting = posting_date(Map.get(attrs, :occurred_on), config.starts_on)

        %FinanceEvent{}
        |> FinanceEvent.changeset(%{
          posting_date: posting,
          kind: attrs.kind,
          classification: attrs.classification,
          property_id: Map.get(attrs, :property_id),
          amount_cents: attrs.amount_cents,
          lot_source_operation_id: Map.get(attrs, :lot_source_operation_id),
          lot_expires_on: Map.get(attrs, :lot_expires_on),
          operation_id: Map.get(attrs, :operation_id)
        })
        |> Repo.insert!()

        :ok
    end
  end

  defp posting_date(nil, starts_on), do: starts_on

  defp posting_date(occurred_on, starts_on) do
    if Date.compare(occurred_on, starts_on) == :lt do
      starts_on
    else
      occurred_on
    end
  end

  defp get_config do
    Repo.one(from r in FinanceReporting, limit: 1)
  end

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp parse_date(%Date{} = date), do: {:ok, date}
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp as_int(n) when is_integer(n), do: n
  defp as_int(n) when is_float(n), do: trunc(n)
  defp as_int(_), do: 0

  defp lot_source(%{"source_operation_id" => id}), do: id
  defp lot_source(%{source_operation_id: id}), do: id
  defp lot_source(_), do: nil

  defp lot_remaining(%{"remaining_cents" => n}), do: n
  defp lot_remaining(%{remaining_cents: n}), do: n
  defp lot_remaining(_), do: 0

  defp lot_expires(%{"expires_on" => value}), do: parse_lot_date(value)
  defp lot_expires(%{expires_on: value}), do: parse_lot_date(value)
  defp lot_expires(_), do: nil

  defp parse_lot_date(%Date{} = date), do: date

  defp parse_lot_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_lot_date(_), do: nil
end
