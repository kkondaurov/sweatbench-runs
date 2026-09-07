defmodule GroupStay.Finance do
  @moduledoc """
  Durable daily finance reporting, independent of the current-state ledger.

  Inception freezes the state at a commit boundary, with expiry evaluated on
  starts_on. Subsequent journal entries commit with domain effects and receipts.
  Available credit schedules an expiry entry for the day after its last usable
  date; later redemption/restoration adjusts that schedule with signed entries.
  Reading an open report only sums the journal and never advances domain state.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Finance.{Inception, Journal, Movement, Position, Report}
  alias GroupStay.Reservations.Booking

  @financial_operations ~w(record_cash_payment apply_hotel_credit cancel_group cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)

  def start(operation) do
    with {:ok, date} <- reporting_date(operation["starts_on"]) do
      if Repo.get(Inception, 1) do
        {:error, %{code: "reporting_already_started"}}
      else
        position = Position.all()

        cash =
          Enum.reduce(position.groups, %{}, fn {_id, group}, cash ->
            Map.update(
              cash,
              group.property_id,
              group.cash_paid_cents,
              &(&1 + group.cash_paid_cents)
            )
          end)

        Repo.insert!(%Inception{
          id: 1,
          starts_on: date,
          cash: cash,
          credit_liability_cents:
            position.lots |> Map.values() |> Enum.map(&Position.liability(&1, date)) |> Enum.sum()
        })

        for {_id, lot} <- position.lots, Date.compare(lot.expires_on, date) != :lt do
          Journal.append(
            operation,
            Date.add(lot.expires_on, 1),
            nil,
            "expired_cents",
            lot.remaining
          )
        end

        {:ok, %{starts_on: date}}
      end
    else
      {:error, code} -> {:error, %{code: code}}
    end
  end

  def reporting_date(value) do
    case Booking.date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  @doc false
  def before_operation(%{"type" => type} = operation) when type in @financial_operations do
    case Repo.get(Inception, 1) do
      nil -> nil
      inception -> {inception.starts_on, Position.for_operation(operation)}
    end
  end

  def before_operation(_operation), do: nil

  @doc false
  def record_applied(nil, _operation), do: :ok

  def record_applied({starts_on, before}, operation) do
    occurred_on = Date.from_iso8601!(operation["occurred_on"])
    posting_on = if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    Journal.record(operation, posting_on, before, Position.refresh(before))
  end

  def daily_report(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(Inception, 1) do
          nil ->
            {:error, "report_not_available"}

          inception ->
            if Date.compare(date, inception.starts_on) == :lt do
              {:error, "report_not_available"}
            else
              # Aggregate in the database so report reads don't load the full journal.
              movements =
                Repo.all(
                  from m in Movement,
                    where: m.posting_on <= ^date,
                    group_by: [m.property_id, m.category, m.posting_on == ^date],
                    select:
                      {m.property_id, m.category, m.posting_on == ^date, sum(m.amount_cents)}
                )

              {:ok, Report.build(inception, movements, date)}
            end
        end
      end)

    result
  end
end
