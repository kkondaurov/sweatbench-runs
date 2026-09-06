defmodule GroupStay.Reservations.CreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :original_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    guest_id
    source_operation_id
    issued_on
    original_cents
    remaining_cents
    expires_on
  )a

  def changeset(credit_lot, attrs) do
    credit_lot
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:original_cents, greater_than: 0)
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
