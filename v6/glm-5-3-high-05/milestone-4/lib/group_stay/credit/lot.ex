defmodule GroupStay.Credit.Lot do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, GroupStay.Credit.Application
    has_many :entitlements, GroupStay.Credit.Entitlement

    timestamps()
  end

  def changeset(lot, attrs) do
    lot
    |> Ecto.Changeset.cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> Ecto.Changeset.validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> Ecto.Changeset.validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:unrecovered_clawback_cents, greater_than_or_equal_to: 0)
  end
end
