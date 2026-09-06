defmodule GroupStay.Reservations.CashFunding do
  use Ecto.Schema

  alias GroupStay.Reservations.Group

  schema "cash_fundings" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer, default: 0
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transfer_participated, :boolean, default: false

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
