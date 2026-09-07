defmodule GroupStay.FinanceReporting.Movement do
  @moduledoc "A classified cash or credit-liability change on its reporting date."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.CreditLot

  schema "finance_movements" do
    field :posting_on, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :scheduled_expiry, :boolean, default: false
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :posting_on,
      :property_id,
      :classification,
      :amount_cents,
      :credit_lot_id,
      :scheduled_expiry
    ])
    |> validate_required([:posting_on, :classification, :amount_cents, :scheduled_expiry])
  end
end
