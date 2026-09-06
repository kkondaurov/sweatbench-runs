defmodule GroupStay.Credits.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :amount_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, GroupStay.Credits.CreditApplication
    has_many :entitlements, GroupStay.Credits.CreditEntitlement

    timestamps(type: :utc_datetime)
  end
end
