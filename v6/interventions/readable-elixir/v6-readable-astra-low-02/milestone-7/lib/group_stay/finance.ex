defmodule GroupStay.Finance do
  @moduledoc """
  Durable opening positions and signed daily finance movements.

  Cash movements are differences in allocation dispositions, preserving settlement
  properties even after transfers. Credit events describe liability changes;
  remaining lot balances also schedule expiry. Changes to those balances amend
  scheduled expiry, so reporting needs neither a daily job nor mutating reads.
  All writes share the partner operation transaction. A durable cutoff prevents
  any new row from posting into a published day, including amendments to expiry.
  Closed reports therefore remain stable without materializing calendar days;
  each row permanently retains its posting date and late-adjustment classification.
  """
  import Ecto.Query
  alias GroupStay.{Operations, Repo}
  alias GroupStay.Reservations.{CashAllocation, CreditLot, Group, HotelCredit}

  @cash ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit ~w(issued expired consumed revoked absorbed)

  def starts_on do
    Repo.one(from r in "finance_reporting", select: type(r.starts_on, :date))
  end

  def latest_cutoff do
    Repo.one(from r in "finance_reporting", select: type(r.closed_through, :date))
  end

  @doc "Publishes a cutoff atomically with the durable partner result."
  def close(on) do
    inception = starts_on()
    cutoff = latest_cutoff()

    if is_nil(inception) or Date.compare(on, inception) == :lt or
         (cutoff && Date.compare(on, cutoff) != :gt) do
      Operations.reject(%{code: "invalid_period"})
    end

    Repo.update_all("finance_reporting", set: [closed_through: on])
    %{period_end_on: on}
  end

  defp posting_date(on) do
    case latest_cutoff() do
      nil -> on
      cutoff -> later(on, Date.add(cutoff, 1))
    end
  end

  def start(on) do
    if starts_on(), do: Operations.reject(%{code: "reporting_already_started"})
    Repo.insert_all("finance_reporting", [%{id: 1, starts_on: on}])

    for {{property, "held"}, amount} <- cash_snapshot() do
      record(on, property, "opening", amount)
    end

    record(on, nil, "opening", HotelCredit.liability(on))

    for lot <- Repo.all(CreditLot), Date.compare(lot.expires_on, on) != :lt do
      record(Date.add(lot.expires_on, 1), nil, "expired", lot.remaining_cents)
    end

    %{starts_on: on}
  end

  def capture(%{"type" => type}, apply)
      when type in ["start_finance_reporting", "close_finance_period"],
      do: apply.()

  def capture(operation, apply) do
    case starts_on() do
      nil ->
        apply.()

      inception ->
        before_cash = cash_snapshot()
        before_lots = lot_snapshot()
        destination_cash = destination_cash(operation)
        result = apply.()
        on = later(Date.from_iso8601!(operation["occurred_on"]), inception)
        cash_changes(before_cash, cash_snapshot(), operation, on, destination_cash)

        after_lots = lot_snapshot()

        for id <- Enum.uniq(Map.keys(before_lots) ++ Map.keys(after_lots)) do
          {old, expiry} =
            case Map.fetch(before_lots, id) do
              {:ok, previous} -> previous
              :error -> {0, elem(Map.fetch!(after_lots, id), 1)}
            end

          {new, _} = Map.get(after_lots, id, {0, expiry})
          # An expired balance is already outside liability. Revoking it neither
          # reverses its historical expiry nor creates another liability outflow.
          unless operation["type"] == "charge_back_payment" and
                   Date.compare(expiry, posting_date(on)) == :lt do
            record(later(Date.add(expiry, 1), on), nil, "expired", new - old)
          end
        end

        result
    end
  end

  def credit(on, classification, amount) do
    if inception = starts_on(), do: record(later(on, inception), nil, classification, amount)
  end

  def revoke_credit(on, expires_on, amount) do
    if inception = starts_on() do
      posted_on = later(on, inception)

      if Date.compare(expires_on, posting_date(posted_on)) != :lt,
        do: record(posted_on, nil, "revoked", amount)
    end
  end

  defp lot_snapshot do
    Map.new(Repo.all(CreditLot), &{&1.id, {&1.remaining_cents, &1.expires_on}})
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

  defp cash_changes(before, after_state, operation, on, destination_cash) do
    keys = Enum.uniq(Map.keys(before) ++ Map.keys(after_state))

    for {property, disposition} = key <- keys do
      delta = Map.get(after_state, key, 0) - Map.get(before, key, 0)

      cond do
        disposition != "held" ->
          record(on, property, disposition, delta)

        operation["type"] == "record_cash_payment" ->
          record(on, property, "received", delta)

        true ->
          :ok
      end
    end

    # Use the moved cash amount even within one property: both columns must
    # describe the transfer rather than disappearing in a net balance delta.
    if operation["type"] == "transfer_deposit" do
      source = Repo.get!(Group, operation["source_group_id"])
      destination = Repo.get!(Group, operation["destination_group_id"])

      amount =
        Repo.one(
          from a in CashAllocation,
            where: a.group_id == ^destination.group_id and a.disposition == "held",
            select: coalesce(sum(a.amount_cents), 0)
        )

      moved = amount - destination_cash
      record(on, source.property_id, "transferred_out", moved)
      record(on, destination.property_id, "transferred_in", moved)
    end
  end

  defp destination_cash(%{"type" => "transfer_deposit", "destination_group_id" => id})
       when is_binary(id) do
    Repo.one(
      from a in CashAllocation,
        where: a.group_id == ^id and a.disposition == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp destination_cash(_), do: 0

  defp record(_, _, _, 0), do: :ok

  defp record(on, property, classification, amount) do
    posted_on = posting_date(on)

    Repo.insert_all("finance_movements", [
      %{
        posted_on: posted_on,
        late: if(Date.compare(posted_on, on) == :gt, do: 1, else: 0),
        property_id: property,
        classification: classification,
        amount_cents: amount
      }
    ])
  end

  def daily_report(value) do
    with {:ok, on} <- parse_date(value) do
      {:ok, result} = Repo.transaction(fn -> read_report(on) end)
      result
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, on} -> {:ok, on}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp parse_date(_), do: {:error, "invalid_reporting_date"}

  defp read_report(on) do
    inception = starts_on()
    cutoff = latest_cutoff()

    if is_nil(inception) or Date.compare(on, inception) == :lt do
      {:error, "report_not_available"}
    else
      rows =
        Repo.all(
          from m in "finance_movements",
            where: m.posted_on <= ^on,
            select: %{
              on: type(m.posted_on, :date),
              property: m.property_id,
              classification: m.classification,
              amount: m.amount_cents,
              late: type(m.late, :boolean)
            }
        )

      by_property = Enum.group_by(rows, & &1.property)

      late_cash =
        by_property
        |> Map.delete(nil)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {property, entries} ->
          %{property_id: property, movements: movements(entries, on, @cash, true)}
        end)
        |> Enum.reject(&zero_movements?(&1.movements))

      cash =
        by_property
        |> Map.delete(nil)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {property, entries} ->
          entries |> position(on, @cash, :cash) |> Map.put(:property_id, property)
        end)
        |> Enum.reject(fn entry ->
          entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
            zero_movements?(entry.movements) and
            not Enum.any?(late_cash, &(&1.property_id == entry.property_id))
        end)

      {:ok,
       %{
         date: on,
         status:
           if(cutoff && Date.compare(on, cutoff) != :gt,
             do: "closed",
             else: "open"
           ),
         late_adjustments: %{
           cash: late_cash,
           credit: movements(Map.get(by_property, nil, []), on, @credit, true)
         },
         cash: cash,
         credit: position(Map.get(by_property, nil, []), on, @credit, :credit)
       }}
    end
  end

  defp position(rows, on, classifications, kind) do
    {earlier, today} = Enum.split_with(rows, &(Date.compare(&1.on, on) == :lt))
    opening_rows = Enum.filter(today, &(&1.classification == "opening"))
    opening = balance(earlier ++ opening_rows)

    movements = movements(today, on, classifications, false)

    closing = opening + balance(Enum.reject(today, &(&1.classification == "opening")))

    case kind do
      :cash ->
        %{opening_held_cents: opening, movements: movements, closing_held_cents: closing}

      :credit ->
        %{
          opening_liability_cents: opening,
          movements: movements,
          closing_liability_cents: closing
        }
    end
  end

  defp zero_movements?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp movements(rows, on, classifications, late?) do
    Map.new(classifications, fn name ->
      amount =
        rows
        |> Enum.filter(&(&1.on == on and &1.classification == name and &1.late == late?))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      {String.to_atom(name <> "_cents"), amount}
    end)
  end

  defp balance(rows) do
    Enum.reduce(rows, 0, fn row, total ->
      sign = if row.classification in ~w(opening received transferred_in issued), do: 1, else: -1
      total + sign * row.amount
    end)
  end

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
end
