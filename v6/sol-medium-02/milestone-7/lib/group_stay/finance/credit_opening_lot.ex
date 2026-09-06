defmodule GroupStay.Finance.CreditOpeningLot do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot

  schema "finance_credit_opening_lots" do
    belongs_to :credit_lot, CreditLot
    field :expires_on, :date
    field :available_cents, :integer
    field :applied_cents, :integer
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :expires_on, :available_cents, :applied_cents])
    |> validate_required([:credit_lot_id, :expires_on, :available_cents, :applied_cents])
    |> validate_number(:available_cents, greater_than_or_equal_to: 0)
    |> validate_number(:applied_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:credit_lot_id)
  end
end
