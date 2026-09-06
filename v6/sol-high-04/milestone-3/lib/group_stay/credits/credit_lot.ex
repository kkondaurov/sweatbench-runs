defmodule GroupStay.Credits.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :applications, GroupStay.Credits.CreditApplication

    timestamps(type: :utc_datetime)
  end
end
