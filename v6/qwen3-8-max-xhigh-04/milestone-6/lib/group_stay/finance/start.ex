defmodule GroupStay.Finance.Start do
  @moduledoc """
  The durable inception point of daily finance reporting.

  The first applied `start_finance_reporting` operation creates the single
  start record. The financial state immediately before that operation is
  processed becomes the opening position on `starts_on`: the held cash of
  every property and the company-wide credit liability, evaluated as of
  `starts_on`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_reporting" do
    field :singleton, :integer
    field :starts_on, :date
    field :opening_held_cents, :map
    field :opening_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
