defmodule GroupStay.Finance.CreditAvailabilityMovement do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_availability_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :amount_cents, :integer

    belongs_to :credit_lot, GroupStay.Credits.CreditLot
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:operation_id, :posting_on, :credit_lot_id, :amount_cents])
    |> validate_required([:operation_id, :posting_on, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, not_equal_to: 0)
    |> unique_constraint([:operation_id, :credit_lot_id])
    |> foreign_key_constraint(:credit_lot_id)
  end
end
