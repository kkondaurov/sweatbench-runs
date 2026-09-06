defmodule GroupStay.Cash.PaymentState do
  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "cash_payment_states" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime_usec)
  end
end
