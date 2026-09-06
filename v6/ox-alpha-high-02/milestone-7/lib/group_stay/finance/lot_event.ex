defmodule GroupStay.Finance.LotEvent do
  @moduledoc """
  Per-lot balance and funding movement used to derive natural credit
  expiries from the reporting history alone.
  """

  use Ecto.Schema

  schema "finance_lot_events" do
    field :posted_on, :date
    field :credit_lot_id, :integer
    field :remaining_delta_cents, :integer, default: 0
    field :funded_delta_cents, :integer, default: 0

    timestamps()
  end
end
