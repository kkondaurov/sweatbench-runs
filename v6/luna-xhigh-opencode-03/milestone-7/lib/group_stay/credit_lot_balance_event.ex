defmodule GroupStay.CreditLotBalanceEvent do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lot_balance_events" do
    field :operation_id, :string
    field :occurred_on, :date
    field :amount_cents, :integer
    field :event_type, :string

    belongs_to :credit_lot, GroupStay.CreditLot, foreign_key: :credit_lot_id
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:credit_lot_id, :operation_id, :occurred_on, :amount_cents, :event_type])
    |> validate_required([
      :credit_lot_id,
      :operation_id,
      :occurred_on,
      :amount_cents,
      :event_type
    ])
  end
end
