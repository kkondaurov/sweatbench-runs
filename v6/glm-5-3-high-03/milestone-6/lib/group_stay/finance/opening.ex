defmodule GroupStay.Finance.Opening do
  @moduledoc """
  The opening held-cash position of one property, observed when finance
  reporting started.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :integer

  schema "finance_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0

    belongs_to :reporting_state, GroupStay.Finance.ReportingState

    timestamps(type: :utc_datetime)
  end
end
