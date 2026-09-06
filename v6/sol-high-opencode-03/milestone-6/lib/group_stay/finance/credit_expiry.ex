defmodule GroupStay.Finance.CreditExpiry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:credit_lot_id, :integer, autogenerate: false}
  schema "finance_credit_expiries" do
    field :posting_on, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(expiry, attrs) do
    expiry
    |> cast(attrs, [:credit_lot_id, :posting_on, :amount_cents])
    |> validate_required([:credit_lot_id, :posting_on, :amount_cents])
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
  end
end
