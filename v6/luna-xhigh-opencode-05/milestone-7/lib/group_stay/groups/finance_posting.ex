defmodule GroupStay.Groups.FinancePosting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_postings" do
    field :operation_id, :string
    field :occurred_on, :date
    field :posting_on, :date
    field :property_id, :string
    field :domain, :string
    field :classification, :string
    field :amount_cents, :integer
    field :reference_id, :string
    field :line_number, :integer
  end

  def changeset(posting, attrs) do
    cast(posting, attrs, [
      :operation_id,
      :occurred_on,
      :posting_on,
      :property_id,
      :domain,
      :classification,
      :amount_cents,
      :reference_id,
      :line_number
    ])
  end
end
