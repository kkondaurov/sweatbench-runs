defmodule GroupStay.Bookings.FinanceCreditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :credit_lot_id, :integer
    field :expires_on, :date
    field :kind, :string
    field :amount_cents, :integer
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :operation_id,
      :posting_on,
      :credit_lot_id,
      :expires_on,
      :kind,
      :amount_cents
    ])
    |> validate_required([
      :operation_id,
      :posting_on,
      :credit_lot_id,
      :expires_on,
      :kind,
      :amount_cents
    ])
  end
end
