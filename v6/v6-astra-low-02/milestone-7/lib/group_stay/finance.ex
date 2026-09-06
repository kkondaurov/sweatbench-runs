defmodule GroupStay.Finance.Start do
  use Ecto.Schema

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening, :map
    field :closed_through, :date
  end
end

defmodule GroupStay.Finance.Entry do
  use Ecto.Schema

  schema "finance_entries" do
    field :posting_on, :date
    field :cash, :map
    field :credit, :map
    field :late_adjustment, :boolean, default: false
  end
end

defmodule GroupStay.Finance do
  @moduledoc "Durable inception and signed accounting deltas; report reads are pure folds."
  import Ecto.Query
  alias GroupStay.{Repo, Group, CreditLot}
  alias GroupStay.Finance.{Start, Entry}

  @cash ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit ~w(issued expired consumed revoked absorbed)

  defp snapshot do
    %{groups: Repo.all(Group), lots: Map.new(Repo.all(CreditLot), &{&1.id, &1})}
  end

  def start(value) do
    on = parse(value)
    unless on, do: throw({:operation_rejected, %{code: "invalid_reporting_date"}})
    if Repo.get(Start, 1), do: throw({:operation_rejected, %{code: "reporting_already_started"}})
    state = snapshot()
    cash = Map.new(cash_totals(state), fn {property, totals} -> {property, totals["held"]} end)

    Repo.insert!(%Start{
      id: 1,
      starts_on: on,
      opening: %{"cash" => cash, "credit" => liability(state, on)}
    })

    for {_, lot} <- state.lots, Date.compare(lot.expires_on, on) != :lt do
      entry(Date.add(lot.expires_on, 1), %{}, %{"expired" => lot.remaining_cents})
    end

    %{starts_on: on}
  end

  def close(value) do
    on = parse(value)
    start = Repo.get(Start, 1)

    unless on && start && Date.compare(on, start.starts_on) != :lt &&
             (is_nil(start.closed_through) || Date.compare(on, start.closed_through) == :gt),
           do: throw({:operation_rejected, %{code: "invalid_period"}})

    # Entries are append-only. All subsequent operation postings and expiry changes
    # fall after this cutoff, so closed reports need no materialized daily snapshots.
    start |> Ecto.Changeset.change(closed_through: on) |> Repo.update!()
    %{period_end_on: on}
  end

  def capture do
    case Repo.get(Start, 1) do
      nil -> nil
      start -> {start, snapshot()}
    end
  end

  def record(nil, _), do: :ok

  def record({start, before}, op) do
    after_state = snapshot()
    original_on = latest(parse(op["occurred_on"]), start.starts_on)

    on =
      if start.closed_through,
        do: latest(original_on, Date.add(start.closed_through, 1)),
        else: original_on

    late? = Date.compare(on, original_on) == :gt
    old = cash_totals(before)
    new = cash_totals(after_state)

    cash =
      Map.new(Enum.uniq(Map.keys(old) ++ Map.keys(new)), fn property ->
        a = Map.get(old, property, %{})
        b = Map.get(new, property, %{})
        delta = fn key -> Map.get(b, key, 0) - Map.get(a, key, 0) end

        movements =
          Map.new(
            ~w(refunded retained converted_to_credit reduced charged_back),
            &{&1, delta.(&1)}
          )

        held_delta = delta.("held")

        movements =
          if op["type"] == "transfer_deposit" do
            # Gross transfers are retained even when both groups share a property.
            source = Enum.find(before.groups, &(&1.group_id == op["source_group_id"]))

            destination =
              Enum.find(after_state.groups, &(&1.group_id == op["destination_group_id"]))

            amount =
              source.cash_paid_cents -
                Enum.find(after_state.groups, &(&1.group_id == source.group_id)).cash_paid_cents

            movements
            |> Map.put("transferred_out", if(source.property_id == property, do: amount, else: 0))
            |> Map.put(
              "transferred_in",
              if(destination.property_id == property, do: amount, else: 0)
            )
          else
            Map.put(movements, "received", held_delta + Enum.sum(Map.values(movements)))
          end

        {property, movements}
      end)

    issued =
      Enum.sum(
        for {id, lot} <- after_state.lots,
            not Map.has_key?(before.lots, id),
            do: lot.remaining_cents
      )

    absorbed =
      Enum.sum(
        for {id, lot} <- before.lots,
            do:
              max(
                lot.unrecovered_clawback_cents - after_state.lots[id].unrecovered_clawback_cents,
                0
              )
      )

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

    # Restored balances include expired excess; absorption is measured separately so
    # refundable settlement cannot be mistaken for non-refundable consumption.
    restored =
      Enum.sum(
        for {id, lot} <- before.lots,
            do: max(after_state.lots[id].remaining_cents - lot.remaining_cents, 0)
      )

    consumed =
      if op["type"] in ~w(cancel_group cancel_rooms),
        do: max(applied(before) - applied(after_state) - restored - absorbed, 0),
        else: 0

    # Compare liability at the posting date. This recognizes expired restorations
    # immediately and avoids revoking balances that already left through expiry.
    expired =
      issued - consumed - revoked - absorbed -
        (liability(after_state, on) - liability(before, on))

    entry(
      on,
      cash,
      %{
        "issued" => issued,
        "expired" => expired,
        "consumed" => consumed,
        "revoked" => revoked,
        "absorbed" => absorbed
      },
      late?
    )

    # Changes to unused credit adjust its future expiry, never a previously posted expiry.
    for {id, lot} <- after_state.lots, Date.compare(lot.expires_on, on) != :lt do
      previous = if before.lots[id], do: before.lots[id].remaining_cents, else: 0
      entry(Date.add(lot.expires_on, 1), %{}, %{"expired" => lot.remaining_cents - previous})
    end
  end

  def daily(value) do
    case parse(value) do
      nil ->
        {:error, "invalid_reporting_date"}

      on ->
        {:ok, result} = Repo.transaction(fn -> report(on) end)
        result
    end
  end

  defp report(on) do
    start = Repo.get(Start, 1)

    if is_nil(start) or Date.compare(on, start.starts_on) == :lt do
      {:error, "report_not_available"}
    else
      entries = Repo.all(from e in Entry, where: e.posting_on <= ^on, order_by: e.id)
      {earlier, today} = Enum.split_with(entries, &(Date.compare(&1.posting_on, on) == :lt))

      {late, ordinary} = Enum.split_with(today, & &1.late_adjustment)

      properties =
        Enum.uniq(Map.keys(start.opening["cash"]) ++ Enum.flat_map(entries, &Map.keys(&1.cash)))
        |> Enum.sort()

      cash =
        Enum.flat_map(properties, fn property ->
          opening =
            Map.get(start.opening["cash"], property, 0) +
              Enum.sum(for e <- earlier, do: cash_net(Map.get(e.cash, property, %{})))

          moves = sum(ordinary, @cash, &Map.get(&1.cash, property, %{}))
          adjustments = sum(late, @cash, &Map.get(&1.cash, property, %{}))
          closing = opening + cash_net(moves) + cash_net(adjustments)

          if opening == 0 and closing == 0 and Enum.all?(moves, fn {_, v} -> v == 0 end) and
               Enum.all?(adjustments, fn {_, v} -> v == 0 end),
             do: [],
             else: [
               %{
                 property_id: property,
                 opening_held_cents: opening,
                 movements: cents(moves),
                 closing_held_cents: closing
               }
             ]
        end)

      opening = start.opening["credit"] + Enum.sum(for e <- earlier, do: credit_net(e.credit))
      moves = sum(ordinary, @credit, & &1.credit)
      credit_adjustments = sum(late, @credit, & &1.credit)

      cash_adjustments =
        Enum.flat_map(properties, fn property ->
          moves = sum(late, @cash, &Map.get(&1.cash, property, %{}))

          if Enum.all?(moves, fn {_, v} -> v == 0 end),
            do: [],
            else: [%{property_id: property, movements: cents(moves)}]
        end)

      {:ok,
       %{
         date: Date.to_iso8601(on),
         status:
           if(start.closed_through && Date.compare(on, start.closed_through) != :gt,
             do: "closed",
             else: "open"
           ),
         late_adjustments: %{cash: cash_adjustments, credit: cents(credit_adjustments)},
         cash: cash,
         credit: %{
           opening_liability_cents: opening,
           movements: cents(moves),
           closing_liability_cents: opening + credit_net(moves) + credit_net(credit_adjustments)
         }
       }}
    end
  end

  defp cash_totals(state) do
    Enum.reduce(state.groups, %{}, fn group, totals ->
      amounts =
        Enum.reduce(group.funding_allocations, %{"held" => 0}, fn slice, acc ->
          if slice["kind"] == "cash",
            do:
              Map.update(
                acc,
                slice["disposition"],
                slice["amount_cents"],
                &(&1 + slice["amount_cents"])
              ),
            else: acc
        end)

      Map.update(
        totals,
        group.property_id,
        amounts,
        &Map.merge(&1, amounts, fn _, a, b -> a + b end)
      )
    end)
  end

  defp applied(state), do: Enum.sum(Enum.map(state.groups, & &1.credit_paid_cents))

  defp liability(state, on),
    do:
      applied(state) +
        Enum.sum(
          for {_, lot} <- state.lots,
              Date.compare(lot.expires_on, on) != :lt,
              do: lot.remaining_cents
        )

  defp latest(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp cash_net(m),
    do:
      Map.get(m, "received", 0) + Map.get(m, "transferred_in", 0) -
        Map.get(m, "transferred_out", 0) -
        Enum.sum(
          for k <- ~w(refunded retained converted_to_credit reduced charged_back),
              do: Map.get(m, k, 0)
        )

  defp credit_net(m),
    do:
      Map.get(m, "issued", 0) -
        Enum.sum(for k <- ~w(expired consumed revoked absorbed), do: Map.get(m, k, 0))

  defp sum(entries, keys, get),
    do:
      Map.new(keys, fn key -> {key, Enum.sum(for e <- entries, do: Map.get(get.(e), key, 0))} end)

  defp cents(m), do: Map.new(m, fn {k, v} -> {k <> "_cents", v} end)

  defp entry(on, cash, credit, late? \\ false) do
    cash =
      Map.reject(cash, fn {_, movements} -> Enum.all?(movements, fn {_, v} -> v == 0 end) end)

    unless Enum.all?(credit, fn {_, v} -> v == 0 end) and map_size(cash) == 0 do
      Repo.insert!(%Entry{posting_on: on, cash: cash, credit: credit, late_adjustment: late?})
    end
  end

  defp parse(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, on} -> on
      _ -> nil
    end
  end

  defp parse(_), do: nil
end
