defmodule GroupStay.Reservations.CreditLotCashSource do
  use Ecto.Schema

  alias GroupStay.Reservations.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lot_cash_sources" do
    field :payment_operation_id, :string
    field :cash_cents, :integer
    field :credit_cents, :integer
    field :source_order, :integer

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime_usec)
  end
end
