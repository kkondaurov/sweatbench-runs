defmodule GroupStay.Groups.FinanceMovement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :kind, :string
    field :amount_cents, :integer
    field :property_id, :string
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :operation_id,
      :posting_on,
      :kind,
      :amount_cents,
      :property_id,
      :credit_lot_id
    ])
    |> validate_required([:operation_id, :posting_on, :kind, :amount_cents])
  end
end
