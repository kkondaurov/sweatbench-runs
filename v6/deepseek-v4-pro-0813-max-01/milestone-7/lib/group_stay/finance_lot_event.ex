defmodule GroupStay.FinanceLotEvent do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_lot_events" do
    field :posting_date, :date
    field :lot_id, :string
    field :pool_delta_cents, :integer, default: 0
    field :applied_delta_cents, :integer, default: 0

    timestamps()
  end
end
