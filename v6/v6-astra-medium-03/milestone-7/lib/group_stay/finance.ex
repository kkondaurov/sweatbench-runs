defmodule GroupStay.Finance do
  @moduledoc "Durable opening position and signed daily finance movements."
  import Ecto.Query
  alias GroupStay.{Repo, Group, CreditLot, Accounting}

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @dispositions %{
    "refunded" => "refunded_cents",
    "retained" => "retained_cents",
    "converted" => "converted_to_credit_cents",
    "reduced" => "reduced_cents",
    "charged_back" => "charged_back_cents"
  }

  def inception do
    Repo.one(
      from f in "finance_reporting",
        select: %{starts_on: f.starts_on, opening: f.opening, closed_through: f.closed_through}
    )
  end

  def start(value) do
    with {:ok, on} <- parse_date(value) do
      if inception() do
        {:error, "reporting_already_started"}
      else
        state = capture()

        cash =
          Map.new(state.cash, fn {property, amounts} ->
            {property, Map.get(amounts, "held", 0)}
          end)

        credit = Enum.sum(for {_, lot} <- state.lots, do: liability(lot, on))

        Repo.insert_all("finance_reporting", [
          %{
            id: 1,
            starts_on: Date.to_iso8601(on),
            opening: Jason.encode!(%{cash: cash, credit: credit})
          }
        ])

        for {_, lot} <- state.lots, Date.compare(lot.expiry, on) == :gt do
          movement(lot.expiry, nil, "expired_cents", lot.remaining)
        end

        {:ok, %{starts_on: on}}
      end
    end
  end

  # The operation transaction holds SQLite's writer lock, so the cutoff and
  # movements are committed in the same order as durable operation records.
  def close(value) do
    with {:ok, on} <- parse_date(value),
         %{starts_on: starts_on, closed_through: cutoff} <- inception(),
         true <- Date.compare(on, as_date(starts_on)) != :lt,
         true <- is_nil(cutoff) or Date.compare(on, as_date(cutoff)) == :gt do
      Repo.update_all("finance_reporting", set: [closed_through: Date.to_iso8601(on)])
      {:ok, %{period_end_on: on}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, on} -> {:ok, on}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  def parse_date(_), do: {:error, "invalid_reporting_date"}

  def capture do
    groups = Map.new(Repo.all(Group), &{&1.group_id, &1})
    states = Accounting.all_states()

    cash =
      Enum.reduce(states, %{}, fn state, acc ->
        property = groups[state["group_id"]].property_id

        Enum.reduce(state["entries"], acc, fn e, acc ->
          if e["kind"] == "cash" do
            Map.update(acc, property, %{e["disposition"] => e["amount"]}, fn amounts ->
              Map.update(amounts, e["disposition"], e["amount"], &(&1 + e["amount"]))
            end)
          else
            acc
          end
        end)
      end)

    held =
      states
      |> Enum.flat_map(& &1["entries"])
      |> Enum.filter(&(&1["kind"] == "credit" and &1["disposition"] == "held"))
      |> Enum.group_by(& &1["lot"])

    clawbacks = Map.new(Repo.all(from c in "lot_clawbacks", select: {c.lot_id, c.amount}))

    lots =
      Map.new(Repo.all(CreditLot), fn lot ->
        {lot.id,
         %{
           remaining: lot.remaining_cents,
           held: Accounting.total(Map.get(held, lot.id, [])),
           debt: Map.get(clawbacks, lot.id, 0),
           expiry: Date.add(lot.expires_on, 1)
         }}
      end)

    %{cash: cash, lots: lots, groups: groups}
  end

  def record(op, before, inception) do
    after_state = capture()
    original = later(Date.from_iso8601!(op["occurred_on"]), as_date(inception.starts_on))

    on =
      if inception.closed_through,
        do: later(original, Date.add(as_date(inception.closed_through), 1)),
        else: original

    posting = {on, Date.compare(on, original) == :gt}

    for property <- Enum.uniq(Map.keys(before.cash) ++ Map.keys(after_state.cash)) do
      old = Map.get(before.cash, property, %{})
      new = Map.get(after_state.cash, property, %{})

      for {disposition, column} <- @dispositions do
        movement(
          posting,
          property,
          column,
          Map.get(new, disposition, 0) - Map.get(old, disposition, 0)
        )
      end
    end

    case op["type"] do
      "record_cash_payment" ->
        movement(
          posting,
          after_state.groups[op["group_id"]].property_id,
          "received_cents",
          op["amount_cents"]
        )

      "transfer_deposit" ->
        source = op["source_group_id"]
        destination = op["destination_group_id"]
        # Use group balances so transfers within one property retain both columns.
        amount =
          before.groups[source].cash_paid_cents - after_state.groups[source].cash_paid_cents

        movement(posting, before.groups[source].property_id, "transferred_out_cents", amount)
        movement(posting, before.groups[destination].property_id, "transferred_in_cents", amount)

      _ ->
        :ok
    end

    for {id, new} <- after_state.lots do
      old = Map.get(before.lots, id, %{remaining: 0, held: 0, debt: 0, expiry: new.expiry})
      issued = if Map.has_key?(before.lots, id), do: 0, else: new.remaining + new.held
      absorbed = max(old.debt - new.debt, 0)
      consumed = if nonrefundable?(op, before.groups), do: max(old.held - new.held, 0), else: 0

      revoked =
        if op["type"] == "charge_back_payment",
          do: max(liability(old, on) - liability(new, on), 0),
          else: 0

      # Residual loss is expired restoration. A signed adjustment also handles
      # backdated funding whose posting date is clamped beyond the lot's expiry.
      expired = liability(old, on) - liability(new, on) + issued - absorbed - consumed - revoked

      for {column, amount} <- [
            {"issued_cents", issued},
            {"absorbed_cents", absorbed},
            {"consumed_cents", consumed},
            {"revoked_cents", revoked},
            {"expired_cents", expired}
          ] do
        movement(posting, nil, column, amount)
      end

      # Future expiry stays ordinary and beyond the cutoff. Published expiry
      # remains intact; the residual above reconciles changes on the posting date.
      if Date.compare(new.expiry, on) == :gt do
        movement(new.expiry, nil, "expired_cents", new.remaining - old.remaining)
      end
    end
  end

  defp nonrefundable?(%{"type" => type} = op, groups)
       when type in ~w(cancel_group cancel_rooms) do
    not GroupStay.Reservations.refundable_on?(
      groups[op["group_id"]],
      Date.from_iso8601!(op["occurred_on"])
    )
  end

  defp nonrefundable?(_, _), do: false

  defp liability(lot, on),
    do: lot.held + if(Date.compare(lot.expiry, on) == :gt, do: lot.remaining, else: 0)

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
  defp as_date(%Date{} = on), do: on
  defp as_date(on), do: Date.from_iso8601!(on)
  defp movement(_, _, _, 0), do: :ok

  defp movement(%Date{} = on, property, column, amount),
    do: movement({on, false}, property, column, amount)

  defp movement({on, late}, property, column, amount) do
    # Schemaless inserts need SQLite's integer representation of a boolean.
    Repo.insert_all("finance_movements", [
      %{
        posting_on: Date.to_iso8601(on),
        property_id: property,
        classification: column,
        amount: amount,
        late: if(late, do: 1, else: 0)
      }
    ])
  end

  def daily(value) do
    with {:ok, on} <- parse_date(value) do
      {:ok, result} = Repo.transaction(fn -> read(on) end, mode: :deferred)
      result
    end
  end

  defp read(on) do
    case inception() do
      nil ->
        {:error, "report_not_available"}

      start ->
        if Date.compare(on, as_date(start.starts_on)) == :lt do
          {:error, "report_not_available"}
        else
          opening = Jason.decode!(start.opening)

          rows =
            Repo.all(
              from m in "finance_movements",
                where: m.posting_on <= ^Date.to_iso8601(on),
                select: %{
                  date: m.posting_on,
                  property: m.property_id,
                  column: m.classification,
                  late: m.late,
                  amount: m.amount
                }
            )

          properties =
            (Map.keys(opening["cash"]) ++ Enum.map(rows, & &1.property))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.sort()

          cash =
            for property <- properties do
              {balance, movements, late, closing} =
                rollup(rows, property, on, opening["cash"][property] || 0, @cash)

              %{
                property_id: property,
                opening_held_cents: balance,
                movements: movements,
                late: late,
                closing_held_cents: closing
              }
            end

          cash =
            Enum.reject(
              cash,
              &(&1.opening_held_cents == 0 and &1.closing_held_cents == 0 and
                  Enum.all?(&1.movements, fn {_, v} -> v == 0 end) and
                  Enum.all?(&1.late, fn {_, v} -> v == 0 end))
            )

          {balance, movements, late, closing} = rollup(rows, nil, on, opening["credit"], @credit)

          {:ok,
           %{
             date: on,
             status:
               if(start.closed_through && Date.compare(on, as_date(start.closed_through)) != :gt,
                 do: "closed",
                 else: "open"
               ),
             cash: Enum.map(cash, &Map.delete(&1, :late)),
             late_adjustments: %{
               cash:
                 for(
                   row <- cash,
                   Enum.any?(row.late, fn {_, v} -> v != 0 end),
                   do: %{property_id: row.property_id, movements: row.late}
                 ),
               credit: late
             },
             credit: %{
               opening_liability_cents: balance,
               movements: movements,
               closing_liability_cents: closing
             }
           }}
        end
    end
  end

  defp rollup(rows, property, on, initial, columns) do
    Enum.reduce(
      Enum.filter(rows, &(&1.property == property)),
      {initial, Map.new(columns, &{&1, 0}), Map.new(columns, &{&1, 0}), initial},
      fn row, {opening, movements, late, closing} ->
        delta =
          row.amount *
            if(row.column in ~w(received_cents transferred_in_cents issued_cents),
              do: 1,
              else: -1
            )

        if as_date(row.date) == on do
          if row.late in [true, 1] do
            {opening, movements, Map.update!(late, row.column, &(&1 + row.amount)),
             closing + delta}
          else
            {opening, Map.update!(movements, row.column, &(&1 + row.amount)), late,
             closing + delta}
          end
        else
          {opening + delta, movements, late, closing + delta}
        end
      end
    )
  end
end
