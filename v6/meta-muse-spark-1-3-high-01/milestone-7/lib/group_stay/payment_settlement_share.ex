defmodule GroupStay.PaymentSettlementShare do
  use Ecto.Schema
  import Ecto.Changeset

  schema "payment_settlement_shares" do
    field :payment_operation_id, :string
    field :settling_group_id, :string
    field :cancel_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    belongs_to :settling_group, GroupStay.Group, foreign_key: :settling_group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [
      :payment_operation_id,
      :settling_group_db_id,
      :settling_group_id,
      :cancel_operation_id,
      :refunded_cents,
      :retained_cents,
      :converted_cents
    ])
    |> validate_required([
      :payment_operation_id,
      :settling_group_id,
      :cancel_operation_id
    ])
  end
end
