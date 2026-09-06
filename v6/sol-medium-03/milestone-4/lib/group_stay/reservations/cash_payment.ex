defmodule GroupStay.Reservations.CashPayment do
  use Ecto.Schema

  alias GroupStay.Reservations.Group

  @primary_key {:operation_id, :string, autogenerate: false}
  schema "cash_payments" do
    field :recorded_cents, :integer
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
