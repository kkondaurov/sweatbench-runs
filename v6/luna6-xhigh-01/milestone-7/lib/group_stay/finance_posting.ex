defmodule GroupStay.FinancePosting do
  use Ecto.Schema

  @primary_key {:operation_id, :string, autogenerate: false}
  schema "finance_postings" do
    field :posting_date, :date
    field :late_adjustment, :boolean, default: false
    field :cash_movements, :map
    field :credit_movements, :map
    field :credit_lot_movements, :map

    timestamps(type: :utc_datetime)
  end
end
