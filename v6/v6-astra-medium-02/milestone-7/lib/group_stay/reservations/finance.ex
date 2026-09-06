defmodule GroupStay.Reservations.Finance.Start do
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :closed_through, :date
    field :opening, :map
  end
end

defmodule GroupStay.Reservations.Finance.Movement do
  use Ecto.Schema

  schema "finance_movements" do
    field :posting_on, :date
    field :late_adjustment, :boolean, default: false
    field :cash, :map
    field :credit, :map
  end
end

defmodule GroupStay.Reservations.Finance do
  @moduledoc "Durable operation deltas and deterministic calendar expiry, independent of report reads."
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Funding, CreditLot}
  alias __MODULE__.{Start, Movement}

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @dispositions ~w(held refunded retained converted_to_credit reduced charged_back)

  def start(on) do
    if Repo.get(Start, 1) do
      {:error, "reporting_already_started"}
    else
      snapshot = snapshot()

      opening = %{
        "cash" =>
          Map.new(snapshot.cash, fn {property, amounts} ->
            {property, Map.get(amounts, "held", 0)}
          end),
        "credit" => liability(snapshot, on)
      }

      Repo.insert!(%Start{id: 1, starts_on: on, opening: opening})
      schedule_expiry(%{}, snapshot.lots, on)
      {:ok, %{starts_on: on}}
    end
  end

  def close(on) do
    with %Start{} = start <- Repo.get(Start, 1),
         true <- Date.compare(on, start.starts_on) != :lt,
         true <- is_nil(start.closed_through) or Date.compare(on, start.closed_through) == :gt do
      Repo.update!(Ecto.Changeset.change(start, closed_through: on))
      {:ok, %{period_end_on: on}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  def before_operation do
    case Repo.get(Start, 1) do
      nil -> nil
      start -> {start, snapshot()}
    end
  end

  def record(nil, _, _), do: :ok
  def record(_, _, %{"status" => "rejected"}), do: :ok

  def record(_, %{"type" => "close_finance_period"}, _), do: :ok

  def record({start, before}, op, _) do
    occurred = Date.from_iso8601!(op["occurred_on"])
    base_on = later(occurred, start.starts_on)

    on =
      if start.closed_through,
        do: later(base_on, Date.add(start.closed_through, 1)),
        else: base_on

    late? = Date.compare(on, base_on) == :gt
    after_state = snapshot()

    cash =
      Map.new(Enum.uniq(Map.keys(before.cash) ++ Map.keys(after_state.cash)), fn property ->
        old = Map.get(before.cash, property, %{})
        new = Map.get(after_state.cash, property, %{})
        delta = fn key -> Map.get(new, key, 0) - Map.get(old, key, 0) end
        movements = Map.new(@cash, &{&1, 0})

        movements =
          Enum.reduce(tl(@dispositions), movements, fn key, acc ->
            Map.put(acc, key <> "_cents", delta.(key))
          end)

        total = Enum.sum(Enum.map(@dispositions, delta))

        movements =
          if op["type"] == "transfer_deposit" do
            movements
            |> Map.put(
              "transferred_in_cents",
              transferred_cash(before, op, property, "destination_group_id")
            )
            |> Map.put(
              "transferred_out_cents",
              transferred_cash(before, op, property, "source_group_id")
            )
          else
            Map.put(movements, "received_cents", total)
          end

        {property, movements}
      end)

    issued =
      Enum.reduce(after_state.lots, 0, fn {id, lot}, sum ->
        if Map.has_key?(before.lots, id), do: sum, else: sum + lot.remaining_cents
      end)

    consumed = after_state.consumed - before.consumed

    absorbed =
      Enum.reduce(before.lots, 0, fn {id, lot}, sum ->
        sum +
          max(lot.unrecovered_clawback_cents - after_state.lots[id].unrecovered_clawback_cents, 0)
      end)

    revoked =
      if op["type"] == "charge_back_payment" do
        Enum.reduce(before.lots, 0, fn {id, lot}, sum ->
          if Date.compare(lot.expires_on, on) == :lt,
            do: sum,
            else: sum + max(lot.remaining_cents - after_state.lots[id].remaining_cents, 0)
        end)
      else
        0
      end

    expired =
      liability(before, on) + issued - consumed - revoked - absorbed - liability(after_state, on)

    insert(
      on,
      cash,
      %{
        "issued_cents" => issued,
        "consumed_cents" => consumed,
        "revoked_cents" => revoked,
        "absorbed_cents" => absorbed,
        "expired_cents" => expired
      },
      late?
    )

    schedule_expiry(before.lots, after_state.lots, on)
  end

  defp snapshot do
    properties = Map.new(Repo.all(Group), &{&1.group_id, &1.property_id})
    funding = Repo.all(from f in Funding, order_by: f.id)

    cash =
      funding
      |> Enum.filter(&is_nil(&1.credit_lot_id))
      |> Enum.reduce(%{}, fn row, acc ->
        property = properties[row.group_id]

        Map.update(acc, property, %{row.disposition => row.amount_cents}, fn amounts ->
          Map.update(amounts, row.disposition, row.amount_cents, &(&1 + row.amount_cents))
        end)
      end)

    %{
      funding: funding,
      properties: properties,
      cash: cash,
      lots: Map.new(Repo.all(CreditLot), &{&1.id, &1}),
      applied:
        funding
        |> Enum.filter(&(not is_nil(&1.credit_lot_id) and &1.disposition == "held"))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum(),
      consumed:
        funding
        |> Enum.filter(&(not is_nil(&1.credit_lot_id) and &1.disposition == "consumed"))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()
    }
  end

  defp transferred_cash(before, op, property, target) do
    if before.properties[op[target]] == property do
      {_, cash} =
        before.funding
        |> Enum.reverse()
        |> Enum.reduce({op["amount_cents"], 0}, fn row, {remaining, cash} ->
          if row.group_id == op["source_group_id"] and row.disposition == "held" do
            taken = min(remaining, row.amount_cents)
            {remaining - taken, cash + if(is_nil(row.credit_lot_id), do: taken, else: 0)}
          else
            {remaining, cash}
          end
        end)

      cash
    else
      0
    end
  end

  defp liability(state, on) do
    state.applied +
      Enum.reduce(state.lots, 0, fn {_, lot}, sum ->
        if Date.compare(lot.expires_on, on) == :lt, do: sum, else: sum + lot.remaining_cents
      end)
  end

  # Expiry corrections are scheduled only after the operation's fixed posting date,
  # which is always beyond the close cutoff. If expiry is already closed, the
  # liability delta above accounts for the correction on the first open day.
  # Remaining-credit deltas also adjust its future expiry. Backdated submissions can
  # thus correct an already-read expiry day without mutating that report on read.
  defp schedule_expiry(before, after_lots, on) do
    for {id, lot} <- after_lots, Date.compare(lot.expires_on, on) != :lt do
      previous =
        case before[id] do
          nil -> 0
          old -> old.remaining_cents
        end

      delta = lot.remaining_cents - previous
      if delta != 0, do: insert(Date.add(lot.expires_on, 1), %{}, %{"expired_cents" => delta})
    end
  end

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp insert(on, cash, credit, late? \\ false),
    do:
      Repo.insert!(%Movement{posting_on: on, cash: cash, credit: credit, late_adjustment: late?})

  def daily_report(on) do
    {:ok, result} = Repo.transaction(fn -> read(on) end, mode: :deferred)
    result
  end

  defp read(on) do
    case Repo.get(Start, 1) do
      nil ->
        {:error, "report_not_available"}

      start ->
        if Date.compare(on, start.starts_on) == :lt do
          {:error, "report_not_available"}
        else
          events = Repo.all(from m in Movement, where: m.posting_on <= ^on, order_by: m.id)
          {prior, today} = Enum.split_with(events, &(Date.compare(&1.posting_on, on) == :lt))

          {late, ordinary} = Enum.split_with(today, & &1.late_adjustment)

          properties =
            Enum.uniq(
              Map.keys(start.opening["cash"]) ++ Enum.flat_map(events, &Map.keys(&1.cash))
            )
            |> Enum.sort()

          cash =
            Enum.map(properties, fn property ->
              opening =
                Map.get(start.opening["cash"], property, 0) +
                  cash_change(sum_cash(prior, property))

              movements = sum_cash(ordinary, property)
              late_movements = sum_cash(late, property)

              %{
                property_id: property,
                opening_held_cents: opening,
                movements: movements,
                closing_held_cents: opening + cash_change(movements) + cash_change(late_movements)
              }
            end)
            |> Enum.reject(
              &(&1.opening_held_cents == 0 and &1.closing_held_cents == 0 and
                  zero?(&1.movements) and zero?(sum_cash(late, &1.property_id)))
            )

          opening = start.opening["credit"] + credit_change(sum_credit(prior))
          movements = sum_credit(ordinary)

          {:ok,
           %{
             date: on,
             status:
               if(start.closed_through && Date.compare(on, start.closed_through) != :gt,
                 do: "closed",
                 else: "open"
               ),
             late_adjustments: %{
               cash:
                 properties
                 |> Enum.map(&%{property_id: &1, movements: sum_cash(late, &1)})
                 |> Enum.reject(&zero?(&1.movements)),
               credit: sum_credit(late)
             },
             cash: cash,
             credit: %{
               opening_liability_cents: opening,
               movements: movements,
               closing_liability_cents:
                 opening + credit_change(movements) + credit_change(sum_credit(late))
             }
           }}
        end
    end
  end

  defp zero?(movements), do: Enum.all?(movements, fn {_, n} -> n == 0 end)

  defp sum_cash(events, property),
    do: sum_maps(Enum.map(events, &Map.get(&1.cash, property, %{})), @cash)

  defp sum_credit(events), do: sum_maps(Enum.map(events, & &1.credit), @credit)

  defp sum_maps(maps, keys),
    do: Map.new(keys, fn key -> {key, Enum.sum(Enum.map(maps, &Map.get(&1, key, 0)))} end)

  defp cash_change(m),
    do:
      m["received_cents"] + m["transferred_in_cents"] - m["transferred_out_cents"] -
        Enum.sum(Enum.map(tl(@dispositions), &m[&1 <> "_cents"]))

  defp credit_change(m), do: m["issued_cents"] - Enum.sum(Enum.map(tl(@credit), &m[&1]))
end
