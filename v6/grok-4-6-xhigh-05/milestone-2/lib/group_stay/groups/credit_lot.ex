defmodule GroupStay.Groups.CreditLot do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :applications, GroupStay.Groups.CreditApplication,
      foreign_key: :lot_id,
      references: :id
  end
end
