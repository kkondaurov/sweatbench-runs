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

  def capture do
    case Repo.get(Inception, 1) do
      nil -> nil
      inception -> {inception.starts_on, position()}
    end
  end

  def record(nil, _operation), do: :ok

  def record({starts_on, before}, operation) do
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
    on = later(occurred_on, starts_on)
    after_position = position()
    record_cash(before, after_position, operation, on)
    record_credit(before, after_position, operation, on)
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

  defp record_cash(before, after_position, operation, on) do
    old = cash_dispositions(before)
    new = cash_dispositions(after_position)

    for {property, disposition} = key <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
        classification = @dispositions[disposition],
        classification != nil do
      insert(on, property, classification, Map.get(new, key, 0) - Map.get(old, key, 0))
    end

    case operation["type"] do
      "record_cash_payment" ->
        property = after_position.groups[operation["group_id"]].property_id
        insert(on, property, "received_cents", operation["amount_cents"])

      "transfer_deposit" ->
        source = operation["source_group_id"]
        destination = operation["destination_group_id"]
        amount = held_in_group(before, source) - held_in_group(after_position, source)
        insert(on, before.groups[source].property_id, "transferred_out_cents", amount)
        insert(on, before.groups[destination].property_id, "transferred_in_cents", amount)

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

  defp record_credit(before, after_position, operation, on) do
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
      insert(on, nil, classification, amount)
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

  defp insert(on, property, classification, amount) do
    Repo.insert!(%Movement{
      posted_on: on,
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

    entries =
      for property <- properties do
        {opening, daily, closing} =
          balances(
            Map.get(inception.opening_cash, property, 0),
            Map.get(cash, property, []),
            on,
            @cash_fields
          )

        %{
          property_id: property,
          opening_held_cents: opening,
          movements: daily,
          closing_held_cents: closing
        }
      end
      |> Enum.reject(fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          Enum.all?(entry.movements, fn {_, amount} -> amount == 0 end)
      end)

    {opening, daily, closing} =
      balances(inception.opening_credit_cents, credit, on, @credit_fields)

    %{
      date: on,
      status: "open",
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

    daily =
      Enum.reduce(today, Map.new(fields, &{&1, 0}), &add(&2, &1.classification, &1.amount_cents))

    {opening, daily, opening + Enum.sum(Enum.map(today, &effect/1))}
  end

  defp effect(%{classification: classification, amount_cents: amount})
       when classification in ~w(received_cents transferred_in_cents issued_cents), do: amount

  defp effect(movement), do: -movement.amount_cents
  defp add(map, key, amount), do: Map.update(map, key, amount, &(&1 + amount))
  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
