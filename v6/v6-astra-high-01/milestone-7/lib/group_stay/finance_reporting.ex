defmodule GroupStay.FinanceReporting do
  @moduledoc "Durable opening positions and signed daily finance movements."
  import Ecto.Query

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    FinanceEntry,
    FundingAllocation,
    Group,
    Operation,
    Operations,
    Repo
  }

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @counters ~w(refunded retained converted_to_credit reduced charged_back)

  # The successful start's durable audit record is the singleton inception marker.
  # It is committed together with the opening entries under the existing writer lock.
  defp inception do
    Repo.one(
      from o in Operation,
        where:
          o.type == "start_finance_reporting" and
            fragment("json_extract(?, '$.status') = 'applied'", o.result),
        select: o.result
    )
  end

  def start(operation) do
    date =
      parse_date(operation["starts_on"]) || Operations.reject(%{code: "invalid_reporting_date"})

    if inception(), do: Operations.reject(%{code: "reporting_already_started"})
    before = snapshot()
    id = operation["operation_id"]

    for {_id, group} <- before.groups do
      entry(id, date, group.property_id, "opening", group.cash_paid_cents)
    end

    for {_id, lot} <- before.lots do
      available = if Date.compare(lot.expires_on, date) == :lt, do: 0, else: lot.remaining_cents
      entry(id, date, nil, "opening", available + lot.applied)

      if available != 0,
        do: entry(id, Date.add(lot.expires_on, 1), nil, "expired_cents", available)
    end

    %{starts_on: date}
  end

  defp cutoff do
    result =
      Repo.one(
        from o in Operation,
          where:
            o.type == "close_finance_period" and
              fragment("json_extract(?, '$.status') = 'applied'", o.result),
          order_by: [desc: o.id],
          limit: 1,
          select: o.result
      )

    if result, do: Date.from_iso8601!(result["period_end_on"])
  end

  def close(operation) do
    date = parse_date(operation["period_end_on"])
    start = inception()
    latest = cutoff()

    unless date && start &&
             Date.compare(date, Date.from_iso8601!(start["starts_on"])) != :lt &&
             (is_nil(latest) || Date.compare(date, latest) == :gt),
           do: Operations.reject(%{code: "invalid_period"})

    # The audit record publishes the cutoff atomically under the writer lock.
    # Entries are append-only, and all later writes (including expiry schedule
    # adjustments) fall after this cutoff, so closed report data is immutable.
    %{period_end_on: date}
  end

  # This runs only for a first submission, inside its domain savepoint. Replays
  # never read current financial state, and rejected operations roll everything back.
  def capture(%{"type" => type}, apply)
      when type in ~w(open_group reschedule_group start_finance_reporting close_finance_period),
      do: apply.()

  def capture(operation, apply) do
    case inception() do
      nil ->
        apply.()

      start ->
        before = snapshot()
        result = apply.()

        original_date =
          later(
            Date.from_iso8601!(operation["occurred_on"]),
            Date.from_iso8601!(start["starts_on"])
          )

        latest = cutoff()
        date = if latest, do: later(original_date, Date.add(latest, 1)), else: original_date
        late = Date.compare(date, original_date) == :gt
        after_state = snapshot()
        post_cash(operation, result, date, late, before.groups, after_state.groups)
        post_credit(operation, date, late, before.lots, after_state.lots)
        result
    end
  end

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def parse_date(_), do: nil

  def daily(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case inception() do
          nil ->
            {:error, :not_found, "report_not_available"}

          start ->
            if Date.compare(date, Date.from_iso8601!(start["starts_on"])) == :lt do
              {:error, :not_found, "report_not_available"}
            else
              {:ok, report(date)}
            end
        end
      end)

    result
  end

  defp snapshot do
    applied =
      Map.new(
        Repo.all(
          from a in CreditAllocation,
            group_by: a.credit_lot_id,
            select: {a.credit_lot_id, sum(a.amount_cents)}
        )
      )

    consumed =
      Map.new(
        Repo.all(
          from a in FundingAllocation,
            where: a.kind == "credit" and a.disposition == "consumed",
            group_by: a.credit_lot_id,
            select: {a.credit_lot_id, sum(a.amount_cents)}
        )
      )

    %{
      groups:
        Map.new(
          Repo.all(
            from g in Group,
              select:
                map(g, [
                  :group_id,
                  :property_id,
                  :cash_paid_cents,
                  :cash_refunded_cents,
                  :cash_retained_cents,
                  :cash_converted_to_credit_cents,
                  :cash_reduced_cents,
                  :cash_charged_back_cents
                ])
          ),
          &{&1.group_id, &1}
        ),
      lots:
        Map.new(Repo.all(CreditLot), fn lot ->
          {lot.id,
           lot
           |> Map.from_struct()
           |> Map.put(:applied, Map.get(applied, lot.id, 0))
           |> Map.put(:consumed, Map.get(consumed, lot.id, 0))}
        end)
    }
  end

  defp post_cash(operation, result, date, late, before, after_state) do
    id = operation["operation_id"]

    for {group_id, group} <- after_state do
      previous = Map.get(before, group_id)

      for name <- @counters do
        field = String.to_existing_atom("cash_#{name}_cents")
        delta = Map.fetch!(group, field) - if(previous, do: Map.fetch!(previous, field), else: 0)
        entry(id, date, group.property_id, name <> "_cents", delta, late)
      end
    end

    case operation["type"] do
      "record_cash_payment" ->
        entry(
          id,
          date,
          after_state[result.group_id].property_id,
          "received_cents",
          result.amount_cents,
          late
        )

      "transfer_deposit" ->
        source = before[operation["source_group_id"]]
        destination = after_state[operation["destination_group_id"]]
        cash = source.cash_paid_cents - after_state[source.group_id].cash_paid_cents
        entry(id, date, source.property_id, "transferred_out_cents", cash, late)
        entry(id, date, destination.property_id, "transferred_in_cents", cash, late)

      _ ->
        :ok
    end
  end

  defp post_credit(operation, date, late, before, after_state) do
    for {lot_id, lot} <- after_state, Map.get(before, lot_id) != lot do
      previous =
        Map.get(before, lot_id, %{
          remaining_cents: 0,
          applied: 0,
          consumed: 0,
          unrecovered_clawback_cents: 0
        })

      remaining_delta = lot.remaining_cents - previous.remaining_cents
      applied_delta = lot.applied - previous.applied
      expiry = Date.add(lot.expires_on, 1)
      unexpired = Date.compare(date, expiry) == :lt
      issued = if Map.has_key?(before, lot_id), do: 0, else: lot.remaining_cents
      consumed = lot.consumed - previous.consumed
      absorbed = max(previous.unrecovered_clawback_cents - lot.unrecovered_clawback_cents, 0)

      revoked =
        if operation["type"] == "charge_back_payment" and unexpired, do: -remaining_delta, else: 0

      liability_delta = applied_delta + if(unexpired, do: remaining_delta, else: 0)

      # Unused balances expire without a write on the expiry day. Every subsequent
      # change appends a signed adjustment to that schedule. Already-expired returns
      # leave liability on the operation's posting date, after shortfall absorption.
      expired = issued - consumed - revoked - absorbed - liability_delta

      for {classification, amount} <- [
            {"issued_cents", issued},
            {"consumed_cents", consumed},
            {"absorbed_cents", absorbed},
            {"revoked_cents", revoked},
            {"expired_cents", expired}
          ],
          do: entry(operation["operation_id"], date, nil, classification, amount, late)

      # Scheduled expiry keeps its own date and is ordinary movement, even when
      # a late operation changes the amount scheduled in a still-open period.
      if unexpired,
        do: entry(operation["operation_id"], expiry, nil, "expired_cents", remaining_delta)
    end
  end

  defp report(date) do
    entries =
      Repo.all(
        from e in FinanceEntry,
          where: e.posted_on <= ^date,
          select: %{
            posted_on: e.posted_on,
            property_id: e.property_id,
            classification: e.classification,
            late_adjustment: e.late_adjustment,
            amount_cents: e.amount_cents
          }
      )

    {credit, cash} = Enum.split_with(entries, &is_nil(&1.property_id))

    cash_balances =
      cash
      |> Enum.group_by(& &1.property_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property, entries} ->
        {opening, movements, late, closing} =
          balances(entries, date, @cash, ~w(received_cents transferred_in_cents))

        {%{
           property_id: property,
           opening_held_cents: opening,
           movements: movements,
           closing_held_cents: closing
         }, late}
      end)
      |> Enum.reject(fn {row, late} ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          zero?(row.movements) and zero?(late)
      end)

    {opening, movements, late_credit, closing} = balances(credit, date, @credit, ~w(issued_cents))
    latest = cutoff()

    %{
      date: date,
      status: if(latest && Date.compare(date, latest) != :gt, do: "closed", else: "open"),
      cash: Enum.map(cash_balances, &elem(&1, 0)),
      late_adjustments: %{
        cash:
          for(
            {row, late} <- cash_balances,
            not zero?(late),
            do: %{property_id: row.property_id, movements: late}
          ),
        credit: late_credit
      },
      credit: %{
        opening_liability_cents: opening,
        movements: movements,
        closing_liability_cents: closing
      }
    }
  end

  defp balances(entries, date, columns, incoming) do
    empty = Map.new(columns, &{&1, 0})

    {opening, movements, late} =
      Enum.reduce(entries, {0, empty, empty}, fn e, {opening, movements, late} ->
        cond do
          e.classification == "opening" or Date.compare(e.posted_on, date) == :lt ->
            {opening + effect(e.classification, e.amount_cents, incoming), movements, late}

          e.late_adjustment ->
            {opening, movements, Map.update!(late, e.classification, &(&1 + e.amount_cents))}

          true ->
            {opening, Map.update!(movements, e.classification, &(&1 + e.amount_cents)), late}
        end
      end)

    closing =
      Enum.reduce(Map.to_list(movements) ++ Map.to_list(late), opening, fn {key, amount}, total ->
        total + effect(key, amount, incoming)
      end)

    {opening, movements, late, closing}
  end

  defp zero?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp effect(key, amount, incoming),
    do: if(key == "opening" or key in incoming, do: amount, else: -amount)

  defp later(a, b), do: if(Date.compare(a, b) == :gt, do: a, else: b)
  defp entry(id, date, property, classification, amount, late \\ false)
  defp entry(_id, _date, _property, _classification, 0, _late), do: :ok

  defp entry(id, date, property, classification, amount, late) do
    Repo.insert!(%FinanceEntry{
      operation_id: id,
      posted_on: date,
      property_id: property,
      classification: classification,
      amount_cents: amount,
      late_adjustment: late
    })
  end
end
