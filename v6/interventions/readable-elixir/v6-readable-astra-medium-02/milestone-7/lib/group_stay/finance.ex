defmodule GroupStay.Finance do
  @moduledoc """
  Durable daily reporting from an explicit inception snapshot.

  Cash disposition differences retain the property of settlement. Credit events
  distinguish the reasons liability leaves, while scheduled expiry entries track
  changes to unused lots. Redeeming credit cancels that portion of its scheduled
  expiry; restoration schedules it again. Reads only sum journal entries, so late
  postings and future expiries require neither replay nor mutation of domain state.
  All writes share the partner operation's transaction and retry boundary.

  Closing advances a durable cutoff under that same transaction's write lock.
  Existing entries never move, and new entries cannot post into the closed period.
  This keeps published reports immutable without materializing one row per day.
  Scheduled expiries remain ordinary movements on their natural date; corrections
  to credit that has already expired are posted in the open period instead.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Finance.Entry}
  alias GroupStay.Reservations.{CashAllocation, CreditLot, Group, HotelCredit, Operation}

  @cash ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit ~w(issued expired consumed revoked absorbed)

  def starts_on do
    Repo.one(from r in "finance_reporting", select: type(r.starts_on, :date))
  end

  defp closed_through do
    Repo.one(from r in "finance_reporting", select: type(r.closed_through, :date))
  end

  @doc "Publishes all reporting days through the cutoff within the operation transaction."
  def close_period(value) do
    start = starts_on()
    cutoff = closed_through()

    with {:ok, date} <- Operation.date(value),
         true <- not is_nil(start) and Date.compare(date, start) != :lt,
         true <- is_nil(cutoff) or Date.compare(date, cutoff) == :gt do
      Repo.update_all("finance_reporting", set: [closed_through: date])
      {:ok, %{period_end_on: date}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  def start(value) do
    with {:ok, date} <- Operation.date(value) do
      if starts_on() do
        {:error, "reporting_already_started"}
      else
        Repo.insert_all("finance_reporting", [%{id: 1, starts_on: date}])

        for {{property, "held"}, amount} <- cash_snapshot(),
            do: write(date, property, "opening", amount)

        write(date, nil, "opening", HotelCredit.liability(date))

        for lot <- Repo.all(CreditLot),
            Date.compare(lot.expires_on, date) != :lt,
            do: write(Date.add(lot.expires_on, 1), nil, "expired", lot.remaining_cents)

        {:ok, %{starts_on: date}}
      end
    else
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  def capture(operation, apply_operation) do
    if is_map(operation) && starts_on() &&
         operation["type"] not in ~w(start_finance_reporting close_finance_period) do
      cash = cash_snapshot()
      lots = lot_snapshot()
      result = apply_operation.()

      if result.status == "applied" do
        on = posting_date(operation["occurred_on"])
        record_cash(cash, cash_snapshot(), operation)
        schedule_expiry(lots, lot_snapshot(), on)
      end

      result
    else
      apply_operation.()
    end
  end

  def posting_date(value) do
    {date, _late?} = posting(value)
    date
  end

  defp posting(value) do
    {:ok, date} = Operation.date(value)
    start = starts_on()
    ordinary = if Date.compare(date, start) == :lt, do: start, else: date
    cutoff = closed_through()

    if cutoff && Date.compare(ordinary, cutoff) != :gt,
      do: {Date.add(cutoff, 1), true},
      else: {ordinary, false}
  end

  defp write_operation(value, property, classification, amount) do
    {date, late?} = posting(value)
    write(date, property, classification, amount, late?)
  end

  @doc "Records a liability event at the operation posting date when reporting is enabled."
  def credit_event(on, classification, amount) do
    if starts_on(), do: write_operation(Date.to_iso8601(on), nil, classification, amount)
    :ok
  end

  def available_at_posting?(lot, on) do
    date = if starts_on(), do: posting_date(Date.to_iso8601(on)), else: on
    Date.compare(lot.expires_on, date) != :lt
  end

  defp cash_snapshot do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        group_by: [g.property_id, a.disposition],
        select: {{g.property_id, a.disposition}, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp lot_snapshot, do: Map.new(Repo.all(CreditLot), &{&1.id, &1})

  defp record_cash(before, after_state, operation) do
    keys = (Map.keys(before) ++ Map.keys(after_state)) |> Enum.uniq()

    for {property, disposition} = key <- keys, disposition != "held" do
      write_operation(
        operation["occurred_on"],
        property,
        disposition,
        Map.get(after_state, key, 0) - Map.get(before, key, 0)
      )
    end

    case operation["type"] do
      "record_cash_payment" ->
        group = Repo.get!(Group, operation["group_id"])

        write_operation(
          operation["occurred_on"],
          group.property_id,
          "received",
          operation["amount_cents"]
        )

      _ ->
        :ok
    end
  end

  def transfer_cash(source, destination, amount, on) do
    if starts_on() do
      write_operation(Date.to_iso8601(on), source.property_id, "transferred_out", amount)
      write_operation(Date.to_iso8601(on), destination.property_id, "transferred_in", amount)
    end
  end

  defp schedule_expiry(before, after_state, on) do
    for {id, lot} <- after_state, Date.compare(lot.expires_on, on) != :lt do
      previous =
        case before[id] do
          nil -> 0
          old -> old.remaining_cents
        end

      write(Date.add(lot.expires_on, 1), nil, "expired", lot.remaining_cents - previous)
    end
  end

  defp write(on, property, classification, amount, late? \\ false)

  defp write(_, _, _, 0, _), do: :ok

  defp write(on, property, classification, amount, late?) do
    Repo.insert!(%Entry{
      posting_on: on,
      property_id: property,
      classification: classification,
      amount_cents: amount,
      late_adjustment: late?
    })
  end

  def daily_report(value) do
    with {:ok, date} <- Operation.date(value) do
      {:ok, result} = Repo.transaction(fn -> read_report(date) end)
      result
    else
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp read_report(date) do
    start = starts_on()

    if is_nil(start) or Date.compare(date, start) == :lt do
      {:error, "report_not_available"}
    else
      entries = Repo.all(from e in Entry, where: e.posting_on <= ^date)
      by_property = Enum.group_by(entries, & &1.property_id)

      cash_accounts =
        by_property
        |> Map.delete(nil)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {property, entries} ->
          {row, late} =
            account(
              entries,
              date,
              @cash,
              ~w(received transferred_in),
              {:opening_held_cents, :closing_held_cents}
            )

          {Map.put(row, :property_id, property), %{property_id: property, movements: late}}
        end)

      cash =
        for {row, late} <- cash_accounts,
            row.opening_held_cents != 0 or row.closing_held_cents != 0 or
              nonzero?(row.movements) or nonzero?(late.movements),
            do: row

      late_cash = for {_, late} <- cash_accounts, nonzero?(late.movements), do: late

      {credit, late_credit} =
        account(
          Map.get(by_property, nil, []),
          date,
          @credit,
          ~w(issued),
          {:opening_liability_cents, :closing_liability_cents}
        )

      cutoff = closed_through()
      status = if cutoff && Date.compare(date, cutoff) != :gt, do: "closed", else: "open"

      {:ok,
       %{
         date: date,
         status: status,
         cash: cash,
         credit: credit,
         late_adjustments: %{cash: late_cash, credit: late_credit}
       }}
    end
  end

  defp nonzero?(movements), do: Enum.any?(movements, fn {_, value} -> value != 0 end)

  defp account(entries, date, classifications, incoming, {opening_key, closing_key}) do
    empty_movements = Map.new(classifications, &{&1 <> "_cents", 0})

    {opening, movements, late} =
      Enum.reduce(entries, {0, empty_movements, empty_movements}, fn entry,
                                                                     {opening, movements, late} ->
        cond do
          entry.classification == "opening" or Date.compare(entry.posting_on, date) == :lt ->
            sign =
              if entry.classification == "opening" or entry.classification in incoming,
                do: 1,
                else: -1

            {opening + sign * entry.amount_cents, movements, late}

          entry.late_adjustment ->
            {opening, movements, add_movement(late, entry)}

          true ->
            {opening, add_movement(movements, entry), late}
        end
      end)

    closing =
      Enum.reduce(classifications, opening, fn name, total ->
        amount = movements[name <> "_cents"] + late[name <> "_cents"]
        total + amount * if(name in incoming, do: 1, else: -1)
      end)

    {%{opening_key => opening, :movements => movements, closing_key => closing}, late}
  end

  defp add_movement(movements, entry) do
    Map.update!(movements, entry.classification <> "_cents", &(&1 + entry.amount_cents))
  end
end
