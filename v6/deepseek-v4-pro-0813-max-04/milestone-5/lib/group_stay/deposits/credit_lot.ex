defmodule GroupStay.Deposits.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, GroupStay.Deposits.CreditApplication, on_delete: :delete_all
    has_many :funding, GroupStay.Deposits.CreditLotFunding, on_delete: :delete_all

    timestamps()
  end
end
