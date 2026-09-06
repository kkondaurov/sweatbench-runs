defmodule GroupStay.Reservations.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :credit_applications, GroupStay.Reservations.CreditApplication
    has_many :credit_entitlements, GroupStay.Reservations.CreditEntitlement

    timestamps(type: :utc_datetime)
  end

  def changeset(credit_lot, attrs) do
    credit_lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> validate_number(:unrecovered_clawback_cents, greater_than_or_equal_to: 0)
  end
end
