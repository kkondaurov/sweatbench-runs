defmodule GroupStay.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer, default: 0
    field :remaining_cents, :integer, default: 0
    field :converted_cash_cents, :integer, default: 0
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :usages, GroupStay.CreditUsage, foreign_key: :credit_lot_id

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :issued_cents,
      :remaining_cents,
      :converted_cash_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :issued_cents,
      :remaining_cents,
      :converted_cash_cents,
      :expires_on
    ])
  end
end
