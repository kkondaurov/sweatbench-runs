defmodule GroupStay.Reservations.CreditApplication do
  use Ecto.Schema

  alias GroupStay.Reservations.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_credit_applications" do
    field :amount_cents, :integer
    field :active, :boolean, default: true

    belongs_to :group, Group, foreign_key: :reservation_id
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime_usec)
  end
end
