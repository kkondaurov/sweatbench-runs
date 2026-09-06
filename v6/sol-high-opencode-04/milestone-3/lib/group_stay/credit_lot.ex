defmodule GroupStay.CreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, GroupStay.WideDate

    has_many :allocations, GroupStay.CreditAllocation

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
  end
end
