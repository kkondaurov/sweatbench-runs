defmodule GroupStay.FinanceCreditOpening do
  use Ecto.Schema

  @primary_key {:credit_lot_id, :binary_id, autogenerate: false}

  schema "finance_credit_openings" do
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on_days, :integer
  end
end
