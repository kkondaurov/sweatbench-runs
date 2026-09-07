defmodule GroupStay.Reservations do
  @moduledoc """
  Read access to group reservation and deposit state.

  Partner mutations are coordinated by `GroupStay.PartnerOperations`, which
  enforces operation ordering and transaction boundaries.
  """

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.{Credits, Payments}

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get(group_id)
    |> Repo.preload(:rooms)
  end

  def get_group(_group_id), do: nil

  def finance_totals(on \\ Date.utc_today()) do
    Payments.ledger_totals()
    |> Map.merge(%{
      credit_liability_cents: Credits.liability_cents(on),
      credit_shortfall_cents: Credits.shortfall_cents()
    })
  end
end
