defmodule GroupStay.CreditLot do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer
    field :applied_cents, :integer

    has_many :applications, GroupStay.CreditApplication, foreign_key: :lot_id

    timestamps()
  end
end
