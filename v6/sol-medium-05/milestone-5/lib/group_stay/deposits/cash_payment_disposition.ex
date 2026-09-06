defmodule GroupStay.Deposits.CashPaymentDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_payment_dispositions" do
    field :cash_payment_id, :integer
    field :group_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [
      :cash_payment_id,
      :group_id,
      :refunded_cents,
      :retained_cents,
      :converted_cents
    ])
    |> validate_required([:cash_payment_id, :group_id])
    |> unique_constraint([:cash_payment_id, :group_id])
  end
end
