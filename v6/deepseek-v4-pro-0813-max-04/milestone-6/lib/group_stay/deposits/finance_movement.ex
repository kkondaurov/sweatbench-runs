defmodule GroupStay.Deposits.FinanceMovement do
  use Ecto.Schema

  @moduledoc """
  One finance-reporting movement committed with an applied partner operation.

  `property_id` is `nil` for company-wide credit movements. `amount_cents`
  carries the signed report amount. Hotel-credit rows may additionally carry
  a `remaining_delta_cents` against a `lot_id`: those deltas reconstruct how
  much of a lot remained at its expiry date even after later operations, so
  date-driven credit expiry can be reported without any submitted operations.
  """

  schema "finance_movements" do
    field :posting_date, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :lot_id, :integer
    field :remaining_delta_cents, :integer
    field :operation_id, :string

    timestamps()
  end
end
