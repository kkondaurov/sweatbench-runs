defmodule GroupStay.CreditLot do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on_days, :integer
    field :expires_on_days, :integer
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, GroupStay.CreditApplication
  end
end
