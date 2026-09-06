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
          credit_liability_cents: Credit.liability(as_of)
        }

      ledger ->
        ledger
        |> serialize()
        |> Map.put(:credit_liability_cents, Credit.liability(as_of))
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

  def settle_cash(refunded_cents, retained_cents, converted_to_credit_cents \\ 0) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)

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
      ledger
      |> Ecto.Changeset.change(
        cash_held_cents: cash_held_cents,
        cash_refunded_cents: cash_refunded_cents,
        cash_retained_cents: cash_retained_cents,
        cash_converted_to_credit_cents: cash_converted_to_credit_cents
      )
      |> Repo.update!()

      :ok
    else
      {:error, :overflow}
    end
  end

  def serialize(ledger) do
    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents,
      cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents || 0,
      credit_liability_cents: ledger.credit_liability_cents || 0
    }
  end

  def refresh_credit_liability(as_of) do
    ledger = Repo.get!(LedgerTotals, @ledger_id)
    credit_liability_cents = Credit.liability(as_of)

    if fits_sqlite_integer?(credit_liability_cents) do
      ledger
      |> Ecto.Changeset.change(credit_liability_cents: credit_liability_cents)
      |> Repo.update!()

      :ok
    else
      {:error, :overflow}
    end
  end

  defp fits_sqlite_integer?(value),
    do: is_integer(value) and value >= -@max_sqlite_integer - 1 and value <= @max_sqlite_integer
end
