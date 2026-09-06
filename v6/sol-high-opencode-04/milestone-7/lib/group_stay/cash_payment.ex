defmodule GroupStay.CashPayment do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_payments" do
    field :operation_id, :string
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :participated_in_transfer, :boolean, default: false

    belongs_to :group, GroupStay.Group, type: :binary_id
    has_many :dispositions, GroupStay.CashPaymentDisposition

    timestamps(type: :utc_datetime)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :operation_id,
      :group_id,
      :recorded_cents,
      :refunded_cents,
      :retained_cents,
      :converted_cents,
      :reduced_cents,
      :charged_back_cents,
      :participated_in_transfer
    ])
    |> validate_required([:operation_id, :group_id, :recorded_cents])
    |> unique_constraint(:operation_id)
  end
end
