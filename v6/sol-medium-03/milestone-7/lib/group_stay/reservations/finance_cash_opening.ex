defmodule GroupStay.Reservations.FinanceCashOpening do
  @moduledoc false

  use Ecto.Schema

  schema "finance_cash_openings" do
    field :property_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
