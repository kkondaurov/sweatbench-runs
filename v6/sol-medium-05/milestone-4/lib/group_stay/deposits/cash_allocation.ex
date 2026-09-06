defmodule GroupStay.Deposits.CashAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :cash_payment_id, :integer
    field :amount_cents, :integer

    belongs_to :payment, GroupStay.Deposits.CashPayment,
      foreign_key: :cash_payment_id,
      define_field: false

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :room_id, :cash_payment_id, :amount_cents])
    |> validate_required([:group_id, :room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
