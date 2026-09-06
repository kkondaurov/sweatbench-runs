defmodule GroupStay.FinanceMovement do
  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :original_posting_on, :date
    field :posting_on, :date
    field :cash_movements, :map
    field :credit_events, :map

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
