defmodule GroupStay.Schemas.FinancePropertyOpening do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:property_id, :string, autogenerate: false}
  schema "finance_property_openings" do
    field :opening_held_cents, :integer

    timestamps()
  end
end
