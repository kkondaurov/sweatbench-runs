defmodule GroupStay.CashPaymentDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_payment_dispositions" do
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :cash_payment, GroupStay.CashPayment
    belongs_to :group, GroupStay.Group, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:cash_payment_id, :group_id, :kind, :amount_cents])
    |> validate_required([:cash_payment_id, :group_id, :kind, :amount_cents])
    |> unique_constraint([:cash_payment_id, :group_id, :kind])
  end
end
