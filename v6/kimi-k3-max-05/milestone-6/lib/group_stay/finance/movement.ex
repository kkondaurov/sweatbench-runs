defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One finance movement posted by an applied partner operation processed after
  reporting started. Cash movements are signed per property; credit movements
  are positive magnitudes per lot in their named classification.
  """
  use Ecto.Schema

  schema "finance_movements" do
    field :posting_date, :date
    field :kind, :string
    field :amount_cents, :integer
    field :operation_id, :string
    field :property_id, :string

    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
