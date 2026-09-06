defmodule GroupStay.Reservations.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date

    has_many :allocations, GroupStay.Reservations.CreditAllocation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :issued_on, :expires_on])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :issued_on,
      :expires_on
    ])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
