defmodule GroupStay.Groups.FinanceEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_events" do
    field :posting_date, :date
    field :kind, :string
    field :classification, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :lot_source_operation_id, :string
    field :lot_expires_on, :date
    field :operation_id, :string
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :posting_date,
      :kind,
      :classification,
      :property_id,
      :amount_cents,
      :lot_source_operation_id,
      :lot_expires_on,
      :operation_id
    ])
    |> validate_required([:posting_date, :kind, :classification, :amount_cents])
  end
end
