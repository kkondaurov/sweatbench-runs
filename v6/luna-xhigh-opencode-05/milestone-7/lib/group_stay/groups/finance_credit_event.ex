defmodule GroupStay.Groups.FinanceCreditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_events" do
    field :operation_id, :string
    field :credit_lot_id, :integer
    field :posting_on, :date
    field :effective_on, :date
    field :event_type, :string
    field :amount_cents, :integer
  end

  def changeset(event, attrs) do
    cast(event, attrs, [
      :operation_id,
      :credit_lot_id,
      :posting_on,
      :effective_on,
      :event_type,
      :amount_cents
    ])
  end
end
