defmodule GroupStay.Reservations.FinanceCreditExpiry do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_credit_expiries" do
    field :posting_date, :date
    field :amount_cents, :integer, default: 0

    belongs_to :credit_lot, CreditLot, foreign_key: :hotel_credit_lot_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    hotel_credit_lot_id
    posting_date
    amount_cents
  )a

  def changeset(expiry, attrs) do
    expiry
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:hotel_credit_lot_id)
    |> unique_constraint(:hotel_credit_lot_id)
  end
end
