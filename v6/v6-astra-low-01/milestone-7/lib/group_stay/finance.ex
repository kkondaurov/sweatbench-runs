defmodule GroupStay.Finance do
  import Ecto.Query
  alias GroupStay.{Repo, Group, CreditLot}

  defmodule Inception do
    use Ecto.Schema

    schema "finance_inception" do
      field :starts_on, :date
      field :position, :map
      field :closed_through, :date
    end
  end

  defmodule Movement do
    use Ecto.Schema

    schema "finance_movements" do
      field :posting_on, :date
      field :property_id, :string
      field :classification, :string
      field :amount_cents, :integer
      field :late, :boolean, default: false
    end
  end

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @dispositions %{
    "refunded" => "refunded_cents",
    "retained" => "retained_cents",
    "converted" => "converted_to_credit_cents",
    "reduced" => "reduced_cents",
    "charged_back" => "charged_back_cents"
  }

  def snapshot, do: %{groups: Repo.all(Group), lots: Repo.all(CreditLot)}
  def inception, do: Repo.get(Inception, 1)

  def start(date) do
    if inception(), do: throw({:operation_rejected, %{code: "reporting_already_started"}})
    state = snapshot()
    cash = Map.new(cash_totals(state), fn {id, totals} -> {id, Map.get(totals, "held", 0)} end)

    Repo.insert!(%Inception{
      id: 1,
      starts_on: date,
      position: %{"cash" => cash, "credit" => liability(state, date)}
    })

    schedule(%{lots: []}, state, date)
    %{starts_on: date}
  end

  # Reports are derived from immutable journal entries. Once the cutoff advances,
  # capture can only append beyond it, and scheduled expiry is later still.
  # This freezes every published day without materializing calendar-day snapshots.
  def close(date) do
    start = inception()

    if is_nil(start) or Date.compare(date, start.starts_on) == :lt or
         (start.closed_through && Date.compare(date, start.closed_through) != :gt),
       do: throw({:operation_rejected, %{code: "invalid_period"}})

    start |> Ecto.Changeset.change(closed_through: date) |> Repo.update!()
    %{period_end_on: date}
  end

  # Capture only first applications, inside the domain/audit transaction.
  def capture(nil, _, _, _), do: :ok

  def capture({start, before}, op, result, after_state) do
    original_date = later(Date.from_iso8601!(op["occurred_on"]), start.starts_on)

    date =
      if start.closed_through,
        do: later(original_date, Date.add(start.closed_through, 1)),
        else: original_date

    late = Date.compare(date, original_date) == :gt
    old = cash_totals(before)
    new = cash_totals(after_state)

    for property <- Enum.uniq(Map.keys(old) ++ Map.keys(new)) do
      a = Map.get(old, property, %{})
      b = Map.get(new, property, %{})

      for {disposition, column} <- @dispositions do
        write(date, property, column, value(b, disposition) - value(a, disposition), late)
      end

      held_delta = value(b, "held") - value(a, "held")

      cond do
        op["type"] == "record_cash_payment" ->
          write(date, property, "received_cents", held_delta, late)

        op["type"] == "transfer_deposit" ->
          # Same-property transfers still expose equal gross movements.
          source = Enum.find(before.groups, &(&1.group_id == op["source_group_id"]))
          destination = Enum.find(before.groups, &(&1.group_id == op["destination_group_id"]))

          moved =
            source.cash_paid_cents -
              Enum.find(after_state.groups, &(&1.group_id == source.group_id)).cash_paid_cents

          if property == source.property_id,
            do: write(date, property, "transferred_out_cents", moved, late)

          if property == destination.property_id,
            do: write(date, property, "transferred_in_cents", moved, late)

        true ->
          :ok
      end
    end

    issued = Map.get(result, :credit_issued_cents, 0)

    absorbed =
      Enum.sum(
        Enum.map(before.lots, fn lot ->
          next = Enum.find(after_state.lots, &(&1.id == lot.id))
          max(lot.unrecovered_cents - next.unrecovered_cents, 0)
        end)
      )

    revoked =
      if op["type"] == "charge_back_payment" do
        Enum.sum(
          Enum.map(before.lots, fn lot ->
            next = Enum.find(after_state.lots, &(&1.id == lot.id))

            if Date.compare(lot.expires_on, date) != :lt,
              do: lot.remaining_cents - next.remaining_cents,
              else: 0
          end)
        )
      else
        0
      end

    consumed =
      if op["type"] in ["cancel_group", "cancel_rooms"] do
        group = Enum.find(before.groups, &(&1.group_id == op["group_id"]))
        next = Enum.find(after_state.groups, &(&1.group_id == group.group_id))

        refundable =
          GroupStay.Accounting.refundable?(group, Date.from_iso8601!(op["occurred_on"]))

        if refundable, do: 0, else: group.credit_paid_cents - next.credit_paid_cents
      else
        0
      end

    # Reconcile at the posting date, not wall-clock time. The residual is
    # expiry on restored credit (or its signed reversal for backdated funding).
    expired =
      issued - consumed - revoked - absorbed -
        (liability(after_state, date) - liability(before, date))

    for {column, amount} <- [
          {"issued_cents", issued},
          {"consumed_cents", consumed},
          {"revoked_cents", revoked},
          {"absorbed_cents", absorbed},
          {"expired_cents", expired}
        ],
        do: write(date, nil, column, amount, late)

    schedule(before, after_state, date)
  end

  # Remaining credit expires without a write on the expiry day. Subsequent
  # consumption/restoration adjusts that scheduled amount with signed entries.
  # Only schedule beyond the committed posting date, so a correction can never
  # rewrite closed expiry. Future expiry itself is ordinary, not a late adjustment.
  defp schedule(before, after_state, date) do
    for lot <- after_state.lots, Date.compare(lot.expires_on, date) != :lt do
      old = Enum.find(before.lots, &(&1.id == lot.id))
      delta = lot.remaining_cents - if(old, do: old.remaining_cents, else: 0)
      write(Date.add(lot.expires_on, 1), nil, "expired_cents", delta)
    end
  end

  defp cash_totals(state) do
    Enum.reduce(state.groups, %{}, fn group, acc ->
      totals =
        Enum.reduce(Enum.filter(group.funding, &(&1["kind"] == "cash")), %{}, fn e, sums ->
          Map.update(sums, e["disposition"], e["amount_cents"], &(&1 + e["amount_cents"]))
        end)

      Map.update(acc, group.property_id, totals, &Map.merge(&1, totals, fn _, a, b -> a + b end))
    end)
  end

  defp liability(state, date) do
    Enum.sum(Enum.map(state.groups, & &1.credit_paid_cents)) +
      Enum.sum(
        for l <- state.lots, Date.compare(l.expires_on, date) != :lt, do: l.remaining_cents
      )
  end

  defp write(date, property, column, amount, late \\ false)
  defp write(_, _, _, 0, _), do: :ok

  defp write(date, property, column, amount, late),
    do:
      Repo.insert!(%Movement{
        posting_on: date,
        property_id: property,
        classification: column,
        amount_cents: amount,
        late: late
      })

  def daily(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case inception() do
          nil ->
            {:error, "report_not_available"}

          start ->
            if Date.compare(date, start.starts_on) == :lt,
              do: {:error, "report_not_available"},
              else: {:ok, report(start, date)}
        end
      end)

    result
  end

  defp report(start, date) do
    entries = Repo.all(from m in Movement, where: m.posting_on <= ^date)

    properties =
      (Map.keys(start.position["cash"]) ++
         Enum.map(entries, & &1.property_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      for property <- properties do
        {opening, moves, late, closing} =
          balances(entries, date, property, Map.get(start.position["cash"], property, 0), @cash)

        %{
          property_id: property,
          opening_held_cents: opening,
          movements: moves,
          closing_held_cents: closing,
          late: late
        }
      end

    cash =
      Enum.reject(cash, fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          Enum.all?(Map.values(row.movements) ++ Map.values(row.late), &(&1 == 0))
      end)

    {opening, moves, late, closing} =
      balances(entries, date, nil, start.position["credit"], @credit)

    %{
      date: date,
      status:
        if(start.closed_through && Date.compare(date, start.closed_through) != :gt,
          do: "closed",
          else: "open"
        ),
      cash: Enum.map(cash, &Map.delete(&1, :late)),
      late_adjustments: %{
        cash:
          for(
            row <- cash,
            Enum.any?(row.late, fn {_, amount} -> amount != 0 end),
            do: %{property_id: row.property_id, movements: row.late}
          ),
        credit: late
      },
      credit: %{
        opening_liability_cents: opening,
        movements: moves,
        closing_liability_cents: closing
      }
    }
  end

  defp balances(entries, date, property, initial, columns) do
    entries = Enum.filter(entries, &(&1.property_id == property))

    opening =
      Enum.reduce(entries, initial, fn e, total ->
        if Date.compare(e.posting_on, date) == :lt, do: total + effect(e), else: total
      end)

    today = Enum.filter(entries, &(&1.posting_on == date))
    moves = sum_movements(Enum.reject(today, & &1.late), columns)
    late = sum_movements(Enum.filter(today, & &1.late), columns)
    closing = Enum.reduce(today, opening, fn e, total -> total + effect(e) end)

    {opening, moves, late, closing}
  end

  defp sum_movements(entries, columns) do
    Enum.reduce(entries, Map.new(columns, &{&1, 0}), fn e, acc ->
      Map.update!(acc, e.classification, &(&1 + e.amount_cents))
    end)
  end

  defp effect(e),
    do:
      e.amount_cents *
        if(e.classification in ~w(received_cents transferred_in_cents issued_cents),
          do: 1,
          else: -1
        )

  defp value(map, key), do: Map.get(map, key, 0)
  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
end
