defmodule GroupStay.Finance do
  @moduledoc """
  Durable daily reporting from an explicit inception snapshot.

  Operation deltas are captured within the domain transaction, before its durable
  result commits. Future expiry entries track changes to unused lot balances;
  reads only sum journal entries and never expire or mutate domain records.
  Posting order can differ from processing order, so movements are signed.
  """
  import Ecto.Query
  alias GroupStay.{Operations, Repo}
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Reservations.Group

  @cash ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit ~w(issued expired consumed revoked absorbed)

  def start(value) do
    on = parse_date(value) || Operations.reject(%{code: "invalid_reporting_date"})
    if inception(), do: Operations.reject(%{code: "reporting_already_started"})
    Repo.insert_all("finance_reporting", [%{id: 1, starts_on: on}])
    state = snapshot()
    for {{property, "held"}, amount} <- state.cash, do: entry(on, property, "opening", amount)
    entry(on, nil, "opening", liability(state, on))

    for lot <- Map.values(state.lots), Date.compare(lot.expires_on, on) != :lt do
      entry(Date.add(lot.expires_on, 1), nil, "expired", lot.remaining_cents)
    end

    %{starts_on: on}
  end

  def capture(op, apply) do
    case inception() do
      nil ->
        apply.()

      starts_on ->
        before = snapshot()
        result = apply.()
        on = later(parse_date(op["occurred_on"]), starts_on)
        record_changes(before, snapshot(), op, result, on)
        result
    end
  end

  defp inception do
    case Repo.one(from r in "finance_reporting", select: r.starts_on) do
      nil -> nil
      value -> parse_date(value)
    end
  end

  defp snapshot do
    properties = Map.new(Repo.all(Group), &{&1.group_id, &1.property_id})
    allocations = Repo.all(CashAllocation)

    group_cash =
      Enum.reduce(allocations, %{}, fn a, totals ->
        if a.disposition == "held",
          do: Map.update(totals, a.group_id, a.amount_cents, &(&1 + a.amount_cents)),
          else: totals
      end)

    cash =
      Enum.reduce(allocations, %{}, fn a, totals ->
        Map.update(
          totals,
          {properties[a.group_id], a.disposition},
          a.amount_cents,
          &(&1 + a.amount_cents)
        )
      end)

    %{
      cash: cash,
      group_cash: group_cash,
      properties: properties,
      lots: Map.new(Repo.all(Lot), &{&1.id, &1}),
      applied: Repo.one(from a in Allocation, select: coalesce(sum(a.amount_cents), 0))
    }
  end

  defp liability(state, on) do
    state.applied +
      Enum.sum(
        for lot <- Map.values(state.lots),
            Date.compare(lot.expires_on, on) != :lt,
            do: lot.remaining_cents
      )
  end

  defp record_changes(before, after_state, op, result, on) do
    record_cash_changes(before, after_state, op, on)
    record_credit_changes(before, after_state, op, result, on)
  end

  defp record_cash_changes(before, after_state, op, on) do
    keys = (Map.keys(before.cash) ++ Map.keys(after_state.cash)) |> Enum.uniq()

    for {property, disposition} = key <- keys, disposition != "held" do
      entry(
        on,
        property,
        disposition,
        Map.get(after_state.cash, key, 0) - Map.get(before.cash, key, 0)
      )
    end

    case op["type"] do
      "record_cash_payment" ->
        entry(on, after_state.properties[op["group_id"]], "received", op["amount_cents"])

      "transfer_deposit" ->
        source = before.properties[op["source_group_id"]]
        destination = before.properties[op["destination_group_id"]]
        # Same-property transfers still have equal gross in/out movements.
        cash_moved =
          Map.get(before.group_cash, op["source_group_id"], 0) -
            Map.get(after_state.group_cash, op["source_group_id"], 0)

        entry(on, source, "transferred_out", cash_moved)
        entry(on, destination, "transferred_in", cash_moved)

      _ ->
        :ok
    end
  end

  defp record_credit_changes(before, after_state, op, result, on) do
    issued = Map.get(result, :credit_issued_cents, 0)

    absorbed =
      Enum.sum(
        for {id, lot} <- before.lots,
            do:
              max(
                lot.unrecovered_clawback_cents - after_state.lots[id].unrecovered_clawback_cents,
                0
              )
      )

    consumed =
      if op["type"] in ~w(cancel_group cancel_rooms) and nonrefundable?(op),
        do: before.applied - after_state.applied,
        else: 0

    revoked =
      if op["type"] == "charge_back_payment" do
        Enum.sum(
          for {id, lot} <- before.lots,
              Date.compare(lot.expires_on, on) != :lt,
              do: lot.remaining_cents - after_state.lots[id].remaining_cents
        )
      else
        0
      end

    # Available balances are valued at posting time, while applied credit has
    # paused expiry. The residual is expiry on restoration (or its signed
    # reversal when a backdated application redeems already-expired credit).
    expired =
      issued - consumed - revoked - absorbed -
        (liability(after_state, on) - liability(before, on))

    for {kind, amount} <- [
          {"issued", issued},
          {"consumed", consumed},
          {"revoked", revoked},
          {"absorbed", absorbed},
          {"expired", expired}
        ],
        do: entry(on, nil, kind, amount)

    for {id, lot} <- after_state.lots, Date.compare(lot.expires_on, on) != :lt do
      previous =
        case before.lots[id] do
          nil -> 0
          old -> old.remaining_cents
        end

      entry(Date.add(lot.expires_on, 1), nil, "expired", lot.remaining_cents - previous)
    end
  end

  defp nonrefundable?(op) do
    group = Repo.get!(Group, op["group_id"])

    not GroupStay.Reservations.CancellationPolicy.refundable?(
      group,
      parse_date(op["occurred_on"])
    )
  end

  defp entry(_, _, _, 0), do: :ok

  defp entry(on, property, kind, amount),
    do:
      Repo.insert_all("finance_movements", [
        %{posted_on: on, property_id: property, classification: kind, amount_cents: amount}
      ])

  def daily_report(value) do
    case parse_date(value) do
      nil ->
        {:error, "invalid_reporting_date"}

      on ->
        {:ok, result} =
          Repo.transaction(fn ->
            start = inception()

            if is_nil(start) or Date.compare(on, start) == :lt,
              do: {:error, "report_not_available"},
              else: {:ok, report(on)}
          end)

        result
    end
  end

  defp report(on) do
    rows =
      Repo.all(
        from m in "finance_movements",
          where: m.posted_on <= ^Date.to_iso8601(on),
          select: map(m, [:posted_on, :property_id, :classification, :amount_cents])
      )

    grouped = Enum.group_by(rows, & &1.property_id)

    cash =
      grouped
      |> Map.delete(nil)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property, entries} ->
        balances(entries, on, @cash, "held") |> Map.put(:property_id, property)
      end)
      |> Enum.reject(fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          Enum.all?(Map.values(row.movements), &(&1 == 0))
      end)

    %{
      date: on,
      status: "open",
      cash: cash,
      credit: balances(Map.get(grouped, nil, []), on, @credit, "liability")
    }
  end

  defp balances(rows, on, kinds, balance) do
    day = Date.to_iso8601(on)

    opening =
      Enum.filter(rows, &(&1.posted_on < day or &1.classification == "opening"))
      |> Enum.map(&effect/1)
      |> Enum.sum()

    movements =
      Map.new(kinds, fn kind ->
        {String.to_atom(kind <> "_cents"),
         Enum.sum(
           for row <- rows,
               row.posted_on == day and row.classification == kind,
               do: row.amount_cents
         )}
      end)

    closing =
      opening +
        Enum.sum(
          for row <- rows,
              row.posted_on == day and row.classification != "opening",
              do: effect(row)
        )

    %{
      String.to_atom("opening_#{balance}_cents") => opening,
      :movements => movements,
      String.to_atom("closing_#{balance}_cents") => closing
    }
  end

  defp effect(row),
    do:
      row.amount_cents *
        if(row.classification in ~w(opening received transferred_in issued), do: 1, else: -1)

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
