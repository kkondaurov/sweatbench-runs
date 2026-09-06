defmodule GroupStay.FinanceEvent do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_events" do
    field :operation_id, :string
    field :posting_on, GroupStay.FinancePostingDate
    field :kind, :string
    field :property_id, :string
    field :expires_on, GroupStay.WideDate
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false

    belongs_to :credit_lot, GroupStay.CreditLot, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :operation_id,
      :posting_on,
      :kind,
      :property_id,
      :credit_lot_id,
      :expires_on,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([:operation_id, :posting_on, :kind, :amount_cents])
  end
end
