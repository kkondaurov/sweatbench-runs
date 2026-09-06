defmodule GroupStay.Deposits.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :applications, GroupStay.Deposits.CreditApplication, on_delete: :delete_all

    timestamps()
  end
end
