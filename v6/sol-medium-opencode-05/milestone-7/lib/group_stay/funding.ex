defmodule GroupStay.Funding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fundings" do
    belongs_to :group, GroupStay.Group, foreign_key: :group_ref
    belongs_to :lot, GroupStay.CreditLot
    field :operation_id, :string
    field :kind, :string
    field :funding_order, :integer
    field :original_amount_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :participated_in_transfer, :boolean, default: false
    has_many :room_allocations, GroupStay.RoomAllocation
    has_many :entitlements, GroupStay.CreditEntitlement
    timestamps(type: :utc_datetime)
  end

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, [
      :group_ref,
      :lot_id,
      :operation_id,
      :kind,
      :funding_order,
      :original_amount_cents,
      :refunded_cents,
      :retained_cents,
      :converted_cents,
      :reduced_cents,
      :charged_back_cents,
      :participated_in_transfer
    ])
    |> validate_required([:group_ref, :kind, :funding_order, :original_amount_cents])
  end
end
