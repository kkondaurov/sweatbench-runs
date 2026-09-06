defmodule GroupStay.Reservations.FinanceCreditLotOpening do
  @moduledoc false

  use Ecto.Schema

  schema "finance_credit_lot_openings" do
    field :credit_lot_id, :integer
    field :expires_on, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
