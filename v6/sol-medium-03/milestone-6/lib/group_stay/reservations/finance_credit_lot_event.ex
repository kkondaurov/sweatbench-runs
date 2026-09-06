defmodule GroupStay.Reservations.FinanceCreditLotEvent do
  @moduledoc false

  use Ecto.Schema

  schema "finance_credit_lot_events" do
    field :credit_lot_id, :integer
    field :operation_id, :string
    field :posting_date, :date
    field :expires_on, :date
    field :kind, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
