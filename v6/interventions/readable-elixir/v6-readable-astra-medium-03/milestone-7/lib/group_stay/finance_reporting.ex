defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Durable daily positions, independent of report read order and submission dates.

  An operation journals the difference between its before and after accounting
  positions inside the same transaction as its durable result. Cash dispositions
  retain the property where funding was held or settled. Credit positions include
  applied funding plus unexpired available balances.

  Available credit also schedules an expiry movement. Changes to availability
  adjust that future movement, so redeeming credit pauses expiry and restoring it
  resumes expiry. These signed adjustments telescope even for backdated submissions;
  no expiry worker or mutation during a report read is needed.

  Closing advances a durable posting floor. Journal entries are never rewritten,
  and new entries (including expiry adjustments) cannot enter a closed period.
  This makes published reports stable without materializing every calendar day.
  Scheduled expiry remains ordinary; operation effects deferred by a close are
  marked separately as late adjustments.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.FinanceReporting.{Inception, Movement}
  alias GroupStay.HotelCredit.{Lot, Allocation}
  alias GroupStay.Payments.CashAllocation
  alias GroupStay.Reservations.{Group, CancellationPolicy}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @dispositions %{
    "refunded" => "refunded_cents",
    "retained" => "retained_cents",
    "converted" => "converted_to_credit_cents",
    "reduced" => "reduced_cents",
    "charged_back" => "charged_back_cents"
  }

  def start(value) do
    with {:ok, on} <- parse_date(value) do
      if Repo.get(Inception, 1) do
        {:error, "reporting_already_started"}
      else
        position = position()

        Repo.insert!(%Inception{
          id: 1,
          starts_on: on,
          opening_cash: held_by_property(position),
          opening_credit_cents: liability(position, on)
        })

        schedule_expiry(%{lots: %{}}, position, on)
        {:ok, %{starts_on: on}}
      end
    end
  end

  def close(value) do
    with {:ok, on} <- parse_date(value),
         %Inception{} = inception <- Repo.get(Inception, 1),
         true <- Date.compare(on, inception.starts_on) != :lt,
         true <-
           is_nil(inception.closed_through) or Date.compare(on, inception.closed_through) == :gt do
      inception |> Ecto.Changeset.change(closed_through: on) |> Repo.update!()
      {:ok, %{period_end_on: on}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  def capture do
    case Repo.get(Inception, 1) do
      nil -> nil
      inception -> {inception, position()}
    end
  end

  def record(nil, _operation), do: :ok

  # Reporting controls have no accounting effects or occurred_on requirement.
  def record(_capture, %{"type" => type})
      when type in ["start_finance_reporting", "close_finance_period"], do: :ok

  def record({inception, before}, operation) do
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
    original_on = later(occurred_on, inception.starts_on)

    on =
      if inception.closed_through,
        do: later(original_on, Date.add(inception.closed_through, 1)),
        else: original_on

    posting = {on, on != original_on}
    after_position = position()
    record_cash(before, after_position, operation, posting)
    record_credit(before, after_position, operation, posting)
    schedule_expiry(before, after_position, on)
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

  defp position do
    %{
      groups: Map.new(Repo.all(Group), &{&1.group_id, &1}),
      cash: Repo.all(CashAllocation),
      lots: Map.new(Repo.all(Lot), &{&1.id, &1}),
      credit: Repo.all(Allocation)
    }
  end

  defp held_by_property(position) do
    position.cash
    |> Enum.filter(&(&1.disposition == "held"))
    |> Enum.reduce(%{}, fn slice, totals ->
      add(totals, position.groups[slice.group_id].property_id, slice.amount_cents)
    end)
  end

  defp cash_dispositions(position) do
    Enum.reduce(position.cash, %{}, fn slice, totals ->
      key = {position.groups[slice.group_id].property_id, slice.disposition}
      add(totals, key, slice.amount_cents)
    end)
  end

  defp record_cash(before, after_position, operation, posting) do
    old = cash_dispositions(before)
    new = cash_dispositions(after_position)

    for {property, disposition} = key <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
        classification = @dispositions[disposition],
        classification != nil do
      insert(posting, property, classification, Map.get(new, key, 0) - Map.get(old, key, 0))
    end

    case operation["type"] do
      "record_cash_payment" ->
        property = after_position.groups[operation["group_id"]].property_id
        insert(posting, property, "received_cents", operation["amount_cents"])

      "transfer_deposit" ->
        source = operation["source_group_id"]
        destination = operation["destination_group_id"]
        amount = held_in_group(before, source) - held_in_group(after_position, source)
        insert(posting, before.groups[source].property_id, "transferred_out_cents", amount)
        insert(posting, before.groups[destination].property_id, "transferred_in_cents", amount)

      _ ->
        :ok
    end
  end

  defp held_in_group(position, id) do
    position.cash
    |> Enum.filter(&(&1.group_id == id and &1.disposition == "held"))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp liability(position, on) do
    available =
      position.lots
      |> Map.values()
      |> Enum.filter(&(Date.compare(&1.expires_on, on) != :lt))
      |> Enum.map(& &1.remaining_cents)
      |> Enum.sum()

    available + Enum.sum(Enum.map(position.credit, & &1.amount_cents))
  end

  defp record_credit(before, after_position, operation, {on, _late?} = posting) do
    issued =
      after_position.lots
      |> Enum.reject(fn {id, _} -> Map.has_key?(before.lots, id) end)
      |> Enum.map(fn {_, lot} -> lot.remaining_cents end)
      |> Enum.sum()

    absorbed =
      Enum.sum(
        for {id, lot} <- before.lots do
          max(
            lot.unrecovered_clawback_cents - after_position.lots[id].unrecovered_clawback_cents,
            0
          )
        end
      )

    revoked =
      if operation["type"] == "charge_back_payment" do
        Enum.sum(
          for {id, lot} <- before.lots, Date.compare(lot.expires_on, on) != :lt do
            lot.remaining_cents - after_position.lots[id].remaining_cents
          end
        )
      else
        0
      end

    consumed = consumed_credit(before, after_position, operation)
    delta = liability(after_position, on) - liability(before, on)
    # After explicit issuance and settlement effects, the remaining liability
    # change is expiry: usually a restoration to an expired lot. A backdated
    # redemption posted after inception can also reverse previously expired
    # availability, so this adjustment deliberately remains signed.
    expired = issued - consumed - revoked - absorbed - delta

    for {classification, amount} <- [
          {"issued_cents", issued},
          {"expired_cents", expired},
          {"consumed_cents", consumed},
          {"revoked_cents", revoked},
          {"absorbed_cents", absorbed}
        ] do
      insert(posting, nil, classification, amount)
    end
  end

  defp consumed_credit(before, after_position, %{"type" => type} = operation)
       when type in ["cancel_group", "cancel_rooms"] do
    group = before.groups[operation["group_id"]]
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

    if CancellationPolicy.refundable?(group, occurred_on) do
      0
    else
      Enum.sum(Enum.map(before.credit, & &1.amount_cents)) -
        Enum.sum(Enum.map(after_position.credit, & &1.amount_cents))
    end
  end

  defp consumed_credit(_, _, _), do: 0

  defp schedule_expiry(before, after_position, on) do
    for {id, lot} <- after_position.lots, Date.compare(lot.expires_on, on) != :lt do
      previous =
        case before.lots[id] do
          nil -> 0
          old -> old.remaining_cents
        end

      insert(Date.add(lot.expires_on, 1), nil, "expired_cents", lot.remaining_cents - previous)
    end
  end

  defp insert(_on, _property, _classification, 0), do: :ok

  defp insert(%Date{} = on, property, classification, amount),
    do: insert({on, false}, property, classification, amount)

  defp insert({on, late?}, property, classification, amount) do
    Repo.insert!(%Movement{
      posted_on: on,
      late_adjustment: late?,
      property_id: property,
      classification: classification,
      amount_cents: amount
    })
  end

  defp read_report(on) do
    case Repo.get(Inception, 1) do
      nil ->
        {:error, "report_not_available"}

      inception ->
        if Date.compare(on, inception.starts_on) == :lt do
          {:error, "report_not_available"}
        else
          movements = Repo.all(from m in Movement, where: m.posted_on <= ^on)
          {:ok, build_report(inception, movements, on)}
        end
    end
  end

  defp build_report(inception, movements, on) do
    {credit, cash} = Enum.split_with(movements, &is_nil(&1.property_id))
    cash = Enum.group_by(cash, & &1.property_id)

    properties = Enum.sort(Enum.uniq(Map.keys(inception.opening_cash) ++ Map.keys(cash)))

    {entries, late_entries} =
      properties
      |> Enum.map(fn property ->
        {opening, daily, late, closing} =
          balances(
            Map.get(inception.opening_cash, property, 0),
            Map.get(cash, property, []),
            on,
            @cash_fields
          )

        entry = %{
          property_id: property,
          opening_held_cents: opening,
          movements: daily,
          closing_held_cents: closing
        }

        {entry, %{property_id: property, movements: late}}
      end)
      |> Enum.unzip()

    late_entries = Enum.reject(late_entries, &all_zero?(&1.movements))
    late_properties = MapSet.new(late_entries, & &1.property_id)

    entries =
      Enum.reject(entries, fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          all_zero?(entry.movements) and not MapSet.member?(late_properties, entry.property_id)
      end)

    {opening, daily, late_credit, closing} =
      balances(inception.opening_credit_cents, credit, on, @credit_fields)

    %{
      date: on,
      status:
        if(inception.closed_through && Date.compare(on, inception.closed_through) != :gt,
          do: "closed",
          else: "open"
        ),
      late_adjustments: %{
        cash: late_entries,
        credit: late_credit
      },
      cash: entries,
      credit: %{
        opening_liability_cents: opening,
        movements: daily,
        closing_liability_cents: closing
      }
    }
  end

  defp balances(initial, movements, on, fields) do
    {today, earlier} = Enum.split_with(movements, &(&1.posted_on == on))
    opening = initial + Enum.sum(Enum.map(earlier, &effect/1))

    {late, ordinary} = Enum.split_with(today, & &1.late_adjustment)

    {opening, sum_movements(ordinary, fields), sum_movements(late, fields),
     opening + Enum.sum(Enum.map(today, &effect/1))}
  end

  defp sum_movements(movements, fields) do
    Enum.reduce(
      movements,
      Map.new(fields, &{&1, 0}),
      &add(&2, &1.classification, &1.amount_cents)
    )
  end

  defp all_zero?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp effect(%{classification: classification, amount_cents: amount})
       when classification in ~w(received_cents transferred_in_cents issued_cents), do: amount

  defp effect(movement), do: -movement.amount_cents
  defp add(map, key, amount), do: Map.update(map, key, amount, &(&1 + amount))
  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
