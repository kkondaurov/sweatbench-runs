defmodule GroupStay.Finance.OpeningCash do
  @moduledoc """
  The cash held on active reservations of one property at the reporting
  inception point. Properties without held cash have no row; they enter the
  reports only once movements touch them.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_opening_cash" do
    field :property_id, :string
    field :opening_held_cents, :integer, default: 0

    belongs_to :reporting, GroupStay.Finance.Reporting

    timestamps(type: :utc_datetime)
  end
end
