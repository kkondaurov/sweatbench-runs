defmodule GroupStay.FinanceReporting do
  @moduledoc "Durable opening positions and signed finance entries, committed with partner operations."
  use Ecto.Schema
  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, FinanceEntry, Group, Repo}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
  end

  def start(op) do
    case parse_date(op["starts_on"]) do
      {:ok, starts_on} ->
        if Repo.get(__MODULE__, 1) do
          %{status: "rejected", code: "reporting_already_started"}
        else
          opening_cash =
            Repo.all(
              from g in Group,
                group_by: g.property_id,
                select: {g.property_id, sum(g.cash_paid_cents)}
            )
            |> Map.new()

          lots = Repo.all(CreditLot)
          applied = Repo.aggregate(CreditAllocation, :sum, :amount_cents) || 0
          available = for lot <- lots, Date.compare(lot.expires_on, starts_on) != :lt, do: lot

          Repo.insert!(%__MODULE__{
            id: 1,
            starts_on: starts_on,
            opening_cash: opening_cash,
            opening_credit_cents: applied + Enum.sum(Enum.map(available, & &1.remaining_cents))
          })

          for lot <- available do
            entry(op, Date.add(lot.expires_on, 1), nil, %{"expired_cents" => lot.remaining_cents})
          end

          %{status: "applied", starts_on: starts_on}
        end

      _ ->
        %{status: "rejected", code: "invalid_reporting_date"}
    end
  end

  # Callers record the cash's current property, including when a provider
  # correction reclassifies a settlement made after a transfer.
  def cash_change(op, property_id, movements) do
    if reporting = Repo.get(__MODULE__, 1) do
      entry(op, posting_date(op, reporting), property_id, movements)
    end
  end

  # Remaining credit has a scheduled expiry; applied credit does not. Every change
  # adjusts that schedule with a signed entry, so late/backdated submissions revise
  # open reports without replaying domain operations or mutating state during reads.
  def credit_change(op, lot, remaining_delta, applied_delta, kind, amount \\ 0) do
    if reporting = Repo.get(__MODULE__, 1) do
      on = posting_date(op, reporting)
      unexpired = Date.compare(lot.expires_on, on) != :lt
      liability_delta = applied_delta + if(unexpired, do: remaining_delta, else: 0)
      issued = if kind == :issued, do: amount, else: 0
      consumed = if kind == :consumed, do: amount, else: 0
      absorbed = if kind == :absorbed, do: amount, else: 0
      revoked = if kind == :revoked and unexpired, do: amount, else: 0

      # After explicit issuance/settlement classifications, the remaining change
      # is expiry: e.g. restoring applied credit after expiry, or a signed expiry
      # adjustment when a backdated redemption posts at a later inception date.
      entry(op, on, nil, %{
        "issued_cents" => issued,
        "consumed_cents" => consumed,
        "absorbed_cents" => absorbed,
        "revoked_cents" => revoked,
        "expired_cents" => issued - consumed - absorbed - revoked - liability_delta
      })

      if unexpired do
        entry(op, Date.add(lot.expires_on, 1), nil, %{"expired_cents" => remaining_delta})
      end
    end
  end

  defp entry(op, on, property, movements) do
    movements = Map.reject(movements, fn {_, amount} -> amount == 0 end)

    if map_size(movements) > 0 do
      Repo.insert!(%FinanceEntry{
        operation_id: op["operation_id"],
        posting_on: on,
        property_id: property,
        movements: movements
      })
    end
  end

  defp posting_date(op, reporting) do
    occurred_on = Date.from_iso8601!(op["occurred_on"])

    if Date.compare(occurred_on, reporting.starts_on) == :lt,
      do: reporting.starts_on,
      else: occurred_on
  end

  def daily_report(date) do
    with {:ok, on} <- parse_date(date) do
      # Inception and all entries must come from a single committed snapshot.
      {:ok, result} = Repo.transaction(fn -> read_report(on) end)
      result
    else
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp read_report(on) do
    case Repo.get(__MODULE__, 1) do
      nil ->
        {:error, "report_not_available"}

      reporting ->
        if Date.compare(on, reporting.starts_on) == :lt do
          {:error, "report_not_available"}
        else
          entries = Repo.all(from e in FinanceEntry, where: e.posting_on <= ^on)
          {previous, today} = Enum.split_with(entries, &(Date.compare(&1.posting_on, on) == :lt))
          previous = sum_entries(previous)
          today = sum_entries(today)

          properties =
            (Map.keys(reporting.opening_cash) ++ Map.keys(previous) ++ Map.keys(today))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.sort()

          cash =
            for property <- properties do
              opening =
                Map.get(reporting.opening_cash, property, 0) +
                  cash_net(Map.get(previous, property, %{}))

              movements = Map.merge(zeroes(@cash_fields), Map.get(today, property, %{}))

              %{
                property_id: property,
                opening_held_cents: opening,
                movements: movements,
                closing_held_cents: opening + cash_net(movements)
              }
            end
            |> Enum.reject(fn row ->
              row.opening_held_cents == 0 and row.closing_held_cents == 0 and
                Enum.all?(row.movements, fn {_, amount} -> amount == 0 end)
            end)

          opening = reporting.opening_credit_cents + credit_net(Map.get(previous, nil, %{}))
          movements = Map.merge(zeroes(@credit_fields), Map.get(today, nil, %{}))

          {:ok,
           %{
             date: on,
             status: "open",
             cash: cash,
             credit: %{
               opening_liability_cents: opening,
               movements: movements,
               closing_liability_cents: opening + credit_net(movements)
             }
           }}
        end
    end
  end

  defp sum_entries(entries) do
    Enum.reduce(entries, %{}, fn entry, totals ->
      Map.update(totals, entry.property_id, entry.movements, fn existing ->
        Map.merge(existing, entry.movements, fn _, a, b -> a + b end)
      end)
    end)
  end

  defp zeroes(fields), do: Map.new(fields, &{&1, 0})

  defp cash_net(movements) do
    Enum.reduce(movements, 0, fn {key, amount}, total ->
      if key in ~w(received_cents transferred_in_cents), do: total + amount, else: total - amount
    end)
  end

  defp credit_net(movements) do
    Enum.reduce(movements, 0, fn {key, amount}, total ->
      if key == "issued_cents", do: total + amount, else: total - amount
    end)
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: {:error, :invalid_date}
end
