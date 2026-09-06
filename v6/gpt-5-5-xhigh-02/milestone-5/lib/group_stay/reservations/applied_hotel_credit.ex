defmodule GroupStay.Reservations.AppliedHotelCredit do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "applied_hotel_credits" do
    field :amount_cents, :integer

    belongs_to :group, Group, foreign_key: :group_pk_id
    belongs_to :credit_lot, CreditLot, foreign_key: :hotel_credit_lot_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    group_pk_id
    hotel_credit_lot_id
    amount_cents
  )a

  def changeset(applied_credit, attrs) do
    applied_credit
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_pk_id)
    |> foreign_key_constraint(:hotel_credit_lot_id)
  end
end
