defmodule GroupStay.Reservations.FinancePosting do
  use Ecto.Schema

  schema "finance_postings" do
    field :reporting_start_id, :integer
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean

    timestamps()
  end
end
