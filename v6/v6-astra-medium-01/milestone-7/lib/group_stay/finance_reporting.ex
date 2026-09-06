defmodule GroupStay.FinanceReporting do
  @moduledoc "Durable inception and signed daily journal, committed with partner operations."
  import Ecto.Query
  alias GroupStay.{Repo, Group, CashAllocation, CreditLot, CreditAllocation}

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  defp inception, do: Repo.one(from r in "finance_reporting", select: type(r.starts_on, :date))

  defp cutoff,
    do: Repo.one(from r in "finance_reporting", select: type(r.closed_through, :date))

  # The operation transaction reserves the writer, serializing closes and postings.
  # Journal entries are append-only and can never be added to a closed date.
  def close(value) do
    starts = inception()
    latest = cutoff()

    with {:ok, on} <- date(value),
         true <- starts != nil and Date.compare(on, starts) != :lt,
         true <- latest == nil or Date.compare(on, latest) == :gt do
      Repo.update_all("finance_reporting", set: [closed_through: on])
      {:ok, %{period_end_on: on}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  def start(value) do
    with {:ok, on} <- date(value) do
      if inception() do
        {:error, "reporting_already_started"}
      else
        state = snapshot()

        opening =
          Enum.reduce(state.groups, %{}, fn {_, g}, acc ->
            Map.update(acc, g.property_id, g.cash_paid_cents, &(&1 + g.cash_paid_cents))
          end)

        Repo.insert_all("finance_reporting", [
          %{
            id: 1,
            starts_on: on,
            opening_cash: Jason.encode!(opening),
            opening_credit: liability(state, on)
          }
        ])

        for {_, lot} <- state.lots, Date.compare(lot.expires_on, on) != :lt do
          entry(Date.add(lot.expires_on, 1), nil, "expired_cents", lot.remaining_cents)
        end

        {:ok, %{starts_on: on}}
      end
    end
  end

  def date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, on} -> {:ok, on}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  def date(_), do: {:error, "invalid_reporting_date"}

  defp snapshot do
    %{
      groups:
        Repo.all(
          from g in Group,
            select:
              map(g, [:group_id, :property_id, :cash_paid_cents, :policy_version, :arrival_on])
        )
        |> Map.new(&{&1.group_id, &1}),
      cash:
        Repo.all(
          from a in CashAllocation,
            group_by: [a.group_id, a.disposition],
            select: {{a.group_id, a.disposition}, sum(a.amount_cents)}
        )
        |> Map.new(),
      lots: Map.new(Repo.all(CreditLot), &{&1.id, &1}),
      applied: Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
    }
  end

  # Capture before/after only for a first submission. Replays never consult domain state.
  def capture, do: if(inception(), do: snapshot())
  def record(nil, _, _), do: :ok
  def record(_, _, %{status: "rejected"}), do: :ok

  def record(_, %{"type" => "close_finance_period"}, _), do: :ok

  def record(before, op, _) do
    after_state = snapshot()
    original = later(Date.from_iso8601!(op["occurred_on"]), inception())
    latest = cutoff()
    posting = if latest, do: later(original, Date.add(latest, 1)), else: original
    on = {posting, posting != original}
    cash_movements(before, after_state, op, on)
    credit_movements(before, after_state, op, on)
  end

  defp cash_movements(before, after_state, op, on) do
    for {id, group} <- after_state.groups,
        disposition <- ~w(refunded retained converted_to_credit reduced charged_back) do
      key = {id, disposition}
      amount = Map.get(after_state.cash, key, 0) - Map.get(before.cash, key, 0)
      entry(on, group.property_id, disposition <> "_cents", amount)
    end

    case op["type"] do
      "record_cash_payment" ->
        entry(
          on,
          after_state.groups[op["group_id"]].property_id,
          "received_cents",
          op["amount_cents"]
        )

      "transfer_deposit" ->
        source = op["source_group_id"]
        destination = op["destination_group_id"]

        amount =
          before.groups[source].cash_paid_cents - after_state.groups[source].cash_paid_cents

        entry(on, before.groups[source].property_id, "transferred_out_cents", amount)
        entry(on, before.groups[destination].property_id, "transferred_in_cents", amount)

      _ ->
        :ok
    end
  end

  defp credit_movements(before, after_state, op, {on, late}) do
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

    consumed =
      if op["type"] in ["cancel_group", "cancel_rooms"] and
           not refundable?(before.groups[op["group_id"]], op["occurred_on"]) do
        before.applied - after_state.applied
      else
        0
      end

    # Residual expiry includes credit restored past expiry, and signed corrections
    # when a backdated redemption changes already-expired opening credit to applied credit.
    expired =
      liability(before, on) + issued - consumed - revoked - absorbed - liability(after_state, on)

    for {key, amount} <- [
          {"issued_cents", issued},
          {"consumed_cents", consumed},
          {"revoked_cents", revoked},
          {"absorbed_cents", absorbed},
          {"expired_cents", expired}
        ] do
      entry({on, late}, nil, key, amount)
    end

    # Scheduled expiry is ordinary and strictly after the operation's posting date.
    # Expiry already inside a closed period is reconciled by the residual above.
    for {id, lot} <- after_state.lots, Date.compare(lot.expires_on, on) != :lt do
      previous =
        case before.lots[id] do
          nil -> 0
          old -> old.remaining_cents
        end

      entry(Date.add(lot.expires_on, 1), nil, "expired_cents", lot.remaining_cents - previous)
    end
  end

  defp refundable?(group, occurred_on) do
    case group.policy_version do
      "advance-nonrefundable" ->
        false

      version ->
        Date.diff(group.arrival_on, Date.from_iso8601!(occurred_on)) >=
          if(version == "flex-14", do: 14, else: 30)
    end
  end

  defp liability(state, on) do
    state.applied +
      Enum.sum(
        for {_, l} <- state.lots, Date.compare(l.expires_on, on) != :lt, do: l.remaining_cents
      )
  end

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
  defp entry(_, _, _, 0), do: :ok

  defp entry(%Date{} = on, property, key, amount),
    do: entry({on, false}, property, key, amount)

  defp entry({on, late}, property, key, amount) do
    Repo.insert_all("finance_movements", [
      %{
        posting_on: on,
        property_id: property,
        classification: key,
        amount_cents: amount,
        late: if(late, do: 1, else: 0)
      }
    ])
  end

  def daily(value) do
    with {:ok, on} <- date(value) do
      {:ok, result} = Repo.transaction(fn -> report(on) end)
      result
    end
  end

  defp report(on) do
    starts = inception()

    if starts == nil or Date.compare(on, starts) == :lt do
      {:error, "report_not_available"}
    else
      base =
        Repo.one(
          from r in "finance_reporting", select: %{cash: r.opening_cash, credit: r.opening_credit}
        )

      cash = Jason.decode!(base.cash)

      rows =
        Repo.all(
          from m in "finance_movements",
            where: m.posting_on <= ^on,
            group_by: [m.posting_on, m.property_id, m.classification, m.late],
            select: %{
              on: type(m.posting_on, :date),
              late: type(m.late, :boolean),
              property: m.property_id,
              key: m.classification,
              amount: sum(m.amount_cents)
            }
        )

      properties =
        (Map.keys(cash) ++ Enum.map(rows, & &1.property))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      entries =
        for property <- properties do
          {opening, movements, late, closing} =
            balances(
              Map.get(cash, property, 0),
              Enum.filter(rows, &(&1.property == property)),
              on,
              @cash
            )

          %{
            property_id: property,
            opening_held_cents: opening,
            movements: movements,
            late: late,
            closing_held_cents: closing
          }
        end

      entries =
        Enum.reject(entries, fn e ->
          e.opening_held_cents == 0 and e.closing_held_cents == 0 and
            Enum.all?(e.movements, fn {_, n} -> n == 0 end) and
            Enum.all?(e.late, fn {_, n} -> n == 0 end)
        end)

      {opening, movements, late, closing} =
        balances(base.credit, Enum.filter(rows, &is_nil(&1.property)), on, @credit)

      latest = cutoff()

      {:ok,
       %{
         date: on,
         status: if(latest && Date.compare(on, latest) != :gt, do: "closed", else: "open"),
         cash: Enum.map(entries, &Map.delete(&1, :late)),
         late_adjustments: %{
           cash:
             for(
               e <- entries,
               Enum.any?(e.late, fn {_, n} -> n != 0 end),
               do: %{property_id: e.property_id, movements: e.late}
             ),
           credit: late
         },
         credit: %{
           opening_liability_cents: opening,
           movements: movements,
           closing_liability_cents: closing
         }
       }}
    end
  end

  defp balances(base, rows, on, keys) do
    opening =
      Enum.reduce(rows, base, fn r, total ->
        if Date.compare(r.on, on) == :lt, do: total + effect(r.key, r.amount), else: total
      end)

    movements = movements(rows, on, keys, false)
    late = movements(rows, on, keys, true)

    closing =
      opening + Enum.sum(for {key, amount} <- movements, do: effect(key, amount)) +
        Enum.sum(for {key, amount} <- late, do: effect(key, amount))

    {opening, movements, late, closing}
  end

  defp movements(rows, on, keys, late) do
    Enum.reduce(rows, Map.new(keys, &{&1, 0}), fn r, acc ->
      if r.on == on and r.late == late,
        do: Map.update!(acc, r.key, &(&1 + r.amount)),
        else: acc
    end)
  end

  defp effect(key, amount) when key in ["received_cents", "transferred_in_cents", "issued_cents"],
    do: amount

  defp effect(_, amount), do: -amount
end
