defmodule GroupStay.Accounting.Payment do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "payment_accountings" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end

  def changeset(payment, attrs) do
    Ecto.Changeset.cast(payment, attrs, [
      :payment_operation_id,
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> Ecto.Changeset.validate_required([:payment_operation_id, :group_id, :recorded_cents])
  end
end
