defmodule GroupStay.Finance.Movement do
  @moduledoc false

  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :lot_id, :integer
    field :expires_on, :date
    field :late, :boolean, default: false

    timestamps()
  end
end
