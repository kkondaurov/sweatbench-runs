defmodule GroupStay.Ledger do
  @moduledoc "Read and update the service-wide cash settlement totals."

  alias GroupStay.Ledger.LedgerTotals
  alias GroupStay.Credit
  alias GroupStay.Repo

  @ledger_id 1
  @max_sqlite_integer 9_223_372_036_854_775_807

  def read(as_of \\ Date.utc_today()) do
    case Repo.get(LedgerTotals, @ledger_id) do
      nil ->
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0,
          credit_liability_cents: Credit.liability(as_of),
          credit_shortfall_cents: Credit.shortfall()
        }

      ledger ->
        ledger
        |> serialize()
        |> Map.put(:credit_liability_cents, Credit.liability(as_of))
        |> Map.put(:credit_shortfall_cents, Credit.shortfall())
    end
  end

  def add_cash(amount_cents) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    cash_held_cents = (ledger.cash_held_cents || 0) + amount_cents

    if fits_sqlite_integer?(cash_held_cents) do
      ledger
      |> Ecto.Changeset.change(cash_held_cents: cash_held_cents)
      |> Repo.update!()

      :ok
    else
      {:error, :overflow}
    end
  end

  def validate_cash_addition(amount_cents) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)

    if fits_sqlite_integer?((ledger.cash_held_cents || 0) + amount_cents),
      do: :ok,
      else: {:error, :overflow}
  end

  def settle_cash(refunded_cents, retained_cents, converted_to_credit_cents \\ 0) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)

    case settlement_values(ledger, refunded_cents, retained_cents, converted_to_credit_cents) do
      {:ok, cash_held_cents, cash_refunded_cents, cash_retained_cents,
       cash_converted_to_credit_cents} ->
        ledger
        |> Ecto.Changeset.change(
          cash_held_cents: cash_held_cents,
          cash_refunded_cents: cash_refunded_cents,
          cash_retained_cents: cash_retained_cents,
          cash_converted_to_credit_cents: cash_converted_to_credit_cents
        )
        |> Repo.update!()

        :ok

      {:error, :overflow} ->
        {:error, :overflow}
    end
  end

  def validate_cash_settlement(refunded_cents, retained_cents, converted_to_credit_cents \\ 0) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)

    case settlement_values(ledger, refunded_cents, retained_cents, converted_to_credit_cents) do
      {:ok, _cash_held, _cash_refunded, _cash_retained, _cash_converted} -> :ok
      {:error, :overflow} -> {:error, :overflow}
    end
  end

  def reduce_cash(amount_cents) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    held = (ledger.cash_held_cents || 0) - amount_cents
    reduced = (ledger.cash_reduced_cents || 0) + amount_cents

    if held >= 0 and fits_sqlite_integer?(held) and fits_sqlite_integer?(reduced) do
      ledger
      |> Ecto.Changeset.change(cash_held_cents: held, cash_reduced_cents: reduced)
      |> Repo.update!()

      :ok
    else
      {:error, :overflow}
    end
  end

  def validate_cash_reduction(amount_cents) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    held = (ledger.cash_held_cents || 0) - amount_cents
    reduced = (ledger.cash_reduced_cents || 0) + amount_cents

    if held >= 0 and fits_sqlite_integer?(held) and fits_sqlite_integer?(reduced),
      do: :ok,
      else: {:error, :overflow}
  end

  def charge_back_cash(held_cents, refunded_cents, retained_cents, converted_cents) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    charged_back_cents = held_cents + refunded_cents + retained_cents + converted_cents

    values = %{
      cash_held_cents: (ledger.cash_held_cents || 0) - held_cents,
      cash_refunded_cents: (ledger.cash_refunded_cents || 0) - refunded_cents,
      cash_retained_cents: (ledger.cash_retained_cents || 0) - retained_cents,
      cash_converted_to_credit_cents:
        (ledger.cash_converted_to_credit_cents || 0) - converted_cents,
      cash_charged_back_cents: (ledger.cash_charged_back_cents || 0) + charged_back_cents
    }

    if values.cash_held_cents >= 0 and values.cash_refunded_cents >= 0 and
         values.cash_retained_cents >= 0 and values.cash_converted_to_credit_cents >= 0 and
         Enum.all?(Map.values(values), &fits_sqlite_integer?/1) do
      ledger |> Ecto.Changeset.change(values) |> Repo.update!()
      :ok
    else
      {:error, :overflow}
    end
  end

  def validate_charge_back_cash(held_cents, refunded_cents, retained_cents, converted_cents) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    charged_back_cents = held_cents + refunded_cents + retained_cents + converted_cents

    values = [
      (ledger.cash_held_cents || 0) - held_cents,
      (ledger.cash_refunded_cents || 0) - refunded_cents,
      (ledger.cash_retained_cents || 0) - retained_cents,
      (ledger.cash_converted_to_credit_cents || 0) - converted_cents,
      (ledger.cash_charged_back_cents || 0) + charged_back_cents
    ]

    if Enum.all?(values, &fits_sqlite_integer?/1) and Enum.all?(Enum.take(values, 4), &(&1 >= 0)),
      do: :ok,
      else: {:error, :overflow}
  end

  def validate_credit_liability(value),
    do: if(fits_sqlite_integer?(value), do: :ok, else: {:error, :overflow})

  def serialize(ledger) do
    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents,
      cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents || 0,
      cash_reduced_cents: ledger.cash_reduced_cents || 0,
      cash_charged_back_cents: ledger.cash_charged_back_cents || 0,
      credit_liability_cents: ledger.credit_liability_cents || 0,
      credit_shortfall_cents: ledger.credit_shortfall_cents || 0
    }
  end

  def refresh_credit_liability(as_of) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    credit_liability_cents = Credit.liability(as_of)

    if fits_sqlite_integer?(credit_liability_cents) do
      ledger
      |> Ecto.Changeset.change(
        credit_liability_cents: credit_liability_cents,
        credit_shortfall_cents: Credit.shortfall()
      )
      |> Repo.update!()

      :ok
    else
      {:error, :overflow}
    end
  end

  defp fits_sqlite_integer?(value),
    do: is_integer(value) and value >= -@max_sqlite_integer - 1 and value <= @max_sqlite_integer

  defp settlement_values(ledger, refunded_cents, retained_cents, converted_to_credit_cents) do
    cash_held_cents =
      (ledger.cash_held_cents || 0) - refunded_cents - retained_cents - converted_to_credit_cents

    cash_refunded_cents = (ledger.cash_refunded_cents || 0) + refunded_cents
    cash_retained_cents = (ledger.cash_retained_cents || 0) + retained_cents

    cash_converted_to_credit_cents =
      (ledger.cash_converted_to_credit_cents || 0) + converted_to_credit_cents

    if Enum.all?(
         [
           cash_held_cents,
           cash_refunded_cents,
           cash_retained_cents,
           cash_converted_to_credit_cents
         ],
         &fits_sqlite_integer?/1
       ) and cash_held_cents >= 0 do
      {:ok, cash_held_cents, cash_refunded_cents, cash_retained_cents,
       cash_converted_to_credit_cents}
    else
      {:error, :overflow}
    end
  end
end
