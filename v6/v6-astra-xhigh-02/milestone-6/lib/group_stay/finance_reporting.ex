defmodule GroupStay.FinanceReporting do
  @moduledoc """
  An immutable opening position and signed finance movements, committed with
  partner operations. Expiry entries are scheduled when available credit changes;
  report reads only sum entries and never expire or otherwise mutate domain data.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.FinanceReporting.{Inception, Movement, Position}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @financial_types ~w(record_cash_payment transfer_deposit cancel_group cancel_rooms apply_hotel_credit reduce_cash_payment charge_back_payment)

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, %{code: "invalid_reporting_date"}}
    end
  end

  def parse_date(_), do: {:error, %{code: "invalid_reporting_date"}}

  def start(operation) do
    if Repo.get(Inception, 1) do
      {:error, %{code: "reporting_already_started"}}
    else
      with {:ok, on} <- parse_date(operation["starts_on"]) do
        position = Position.read()
        Repo.insert!(%Inception{id: 1, starts_on: on, opening: Position.opening(position, on)})

        events =
          Enum.reduce(position.lots, %{}, fn {_, lot}, events ->
            schedule_expiry(events, lot, lot.remaining, on)
          end)

        persist(events, operation["operation_id"])
        {:ok, on}
      end
    end
  end

  # This callback runs only for a first submission, inside its domain savepoint.
  # Replays/conflicts bypass it, and audit or reporting failures roll it all back.
  def track(%{"type" => type} = operation, apply_operation) when type in @financial_types do
    case Repo.get(Inception, 1) do
      nil ->
        apply_operation.(operation)

      inception ->
        guest_id = Position.guest_for(operation)
        before = Position.read(guest_id)
        result = apply_operation.(operation)

        if elem(result, 0) == :ok do
          on = later(Date.from_iso8601!(operation["occurred_on"]), inception.starts_on)
          after_position = Position.read(guest_id)
          cash = cash_movements(before, after_position, type)

          %{on => %{cash: cash, credit: %{}}}
          |> credit_movements(before, after_position, type, on)
          |> persist(operation["operation_id"])
        end

        result
    end
  end

  def track(operation, apply_operation), do: apply_operation.(operation)

  def daily_report(on) do
    {:ok, result} =
      Repo.transact(fn ->
        case Repo.get(Inception, 1) do
          nil -> {:ok, {:error, %{code: "report_not_available"}}}
          inception -> {:ok, report(inception, on)}
        end
      end)

    result
  end

  defp report(inception, on) do
    if Date.compare(on, inception.starts_on) == :lt do
      {:error, %{code: "report_not_available"}}
    else
      entries = Repo.all(from m in Movement, where: m.posted_on <= ^on)
      {today, previous} = Enum.split_with(entries, &(&1.posted_on == on))

      opening =
        Enum.reduce(previous, inception.opening, fn entry, opening ->
          cash =
            Enum.reduce(entry.cash, opening["cash"], fn {property, movements}, cash ->
              Map.update(cash, property, cash_net(movements), &(&1 + cash_net(movements)))
            end)

          %{"cash" => cash, "credit" => opening["credit"] + credit_net(entry.credit)}
        end)

      cash = Enum.reduce(today, %{}, &merge_cash(&2, &1.cash))
      credit = Enum.reduce(today, zeros(@credit_fields), &add(&2, &1.credit))

      properties = Enum.uniq(Map.keys(opening["cash"]) ++ Map.keys(cash)) |> Enum.sort()

      cash =
        Enum.map(properties, fn property ->
          balance = Map.get(opening["cash"], property, 0)
          movements = Map.merge(zeros(@cash_fields), Map.get(cash, property, %{}))

          %{
            property_id: property,
            opening_held_cents: balance,
            movements: movements,
            closing_held_cents: balance + cash_net(movements)
          }
        end)
        |> Enum.reject(fn row ->
          row.opening_held_cents == 0 and row.closing_held_cents == 0 and
            Enum.all?(row.movements, fn {_, amount} -> amount == 0 end)
        end)

      {:ok,
       %{
         date: on,
         status: "open",
         cash: cash,
         credit: %{
           opening_liability_cents: opening["credit"],
           movements: credit,
           closing_liability_cents: opening["credit"] + credit_net(credit)
         }
       }}
    end
  end

  defp cash_movements(before, after_position, type) do
    keys = Enum.uniq(Map.keys(before.cash) ++ Map.keys(after_position.cash))

    Enum.reduce(keys, %{}, fn {group_id, disposition} = key, totals ->
      delta = Map.get(after_position.cash, key, 0) - Map.get(before.cash, key, 0)
      property = Map.fetch!(after_position.properties, group_id)

      movements =
        cond do
          type == "transfer_deposit" and disposition == "held" ->
            if delta >= 0,
              do: %{"transferred_in_cents" => delta},
              else: %{"transferred_out_cents" => -delta}

          type == "record_cash_payment" ->
            %{"received_cents" => delta}

          disposition != "held" ->
            %{(disposition <> "_cents") => delta}

          true ->
            %{}
        end

      merge_cash(totals, %{property => movements})
    end)
  end

  defp credit_movements(events, before, after_position, type, on) do
    Enum.reduce(after_position.lots, events, fn {id, lot}, events ->
      original = Map.get(before.lots, id)
      old = original || %{lot | remaining: 0, applied: 0, consumed: 0, clawback: 0}
      remaining_delta = lot.remaining - old.remaining
      issued = if original == nil, do: lot.remaining, else: 0
      consumed = lot.consumed - old.consumed
      absorbed = max(old.clawback - lot.clawback, 0)

      revoked =
        if type == "charge_back_payment" and Date.compare(lot.expires_on, on) != :lt,
          do: -remaining_delta,
          else: 0

      # Only available, unexpired credit and applied credit are liabilities.
      # This also handles restoration after expiry, and operations clamped to an
      # inception later than the lot's expiry, without double-counting revocation.
      liability_delta = Position.liability(lot, on) - Position.liability(old, on)
      expired = issued - consumed - revoked - absorbed - liability_delta

      events
      |> add_credit(on, %{
        "issued_cents" => issued,
        "consumed_cents" => consumed,
        "absorbed_cents" => absorbed,
        "revoked_cents" => revoked,
        "expired_cents" => expired
      })
      |> schedule_expiry(lot, remaining_delta, on)
    end)
  end

  # Changes before expiry adjust that day's future expiry entry. Changes after
  # expiry affect only the operation's posting date; history stays intact.
  defp schedule_expiry(events, lot, amount, on) do
    # The day after 9999-12-31 is outside the API/Ecto ISO date range.
    if amount != 0 and Date.compare(lot.expires_on, on) != :lt and
         Date.compare(lot.expires_on, ~D[9999-12-31]) == :lt do
      add_credit(events, Date.add(lot.expires_on, 1), %{"expired_cents" => amount})
    else
      events
    end
  end

  defp add_credit(events, on, credit) do
    Map.update(events, on, %{cash: %{}, credit: credit}, fn event ->
      %{event | credit: add(event.credit, credit)}
    end)
  end

  defp persist(events, operation_id) do
    for {on, event} <- events do
      cash =
        event.cash
        |> Map.new(fn {property, movements} -> {property, nonzero(movements)} end)
        |> Map.reject(fn {_, movements} -> movements == %{} end)

      credit = nonzero(event.credit)

      if cash != %{} or credit != %{} do
        Repo.insert!(%Movement{
          operation_id: operation_id,
          posted_on: on,
          cash: cash,
          credit: credit
        })
      end
    end
  end

  defp cash_net(movements) do
    Enum.reduce(movements, 0, fn {field, amount}, total ->
      total + if(field in ~w(received_cents transferred_in_cents), do: amount, else: -amount)
    end)
  end

  defp credit_net(movements) do
    Enum.reduce(movements, 0, fn {field, amount}, total ->
      total + if(field == "issued_cents", do: amount, else: -amount)
    end)
  end

  defp zeros(fields), do: Map.new(fields, &{&1, 0})
  defp nonzero(amounts), do: Map.reject(amounts, fn {_, amount} -> amount == 0 end)
  defp add(left, right), do: Map.merge(left, right, fn _, a, b -> a + b end)
  defp merge_cash(left, right), do: Map.merge(left, right, fn _, a, b -> add(a, b) end)
  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
end
