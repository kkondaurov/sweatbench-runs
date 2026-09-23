defmodule GroupStay.Ledger.CashPayment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  @foreign_key_type :string
  schema "cash_payments" do
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transferred, :boolean, default: false

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :payment_operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :transferred
    ])
    |> validate_required([:payment_operation_id, :group_id, :recorded_cents])
  end
end
