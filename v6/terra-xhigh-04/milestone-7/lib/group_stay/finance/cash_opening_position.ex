defmodule GroupStay.Finance.CashOpeningPosition do
  @moduledoc false

  use Ecto.Schema

  schema "finance_cash_opening_positions" do
    field :property_id, :string
    field :held_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
