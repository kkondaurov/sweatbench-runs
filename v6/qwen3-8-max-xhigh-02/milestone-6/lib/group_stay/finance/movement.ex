defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One finance movement posted by an applied partner operation.

  Cash movements carry the property where the cash is held or settled;
  credit movements are company-wide and may reference the affected lot.
  The posting date is the later of the operation's `occurred_on` and the
  reporting `starts_on`.
  """

  use Ecto.Schema

  alias GroupStay.Groups.CreditLot

  schema "finance_movements" do
    field :posting_date, :date
    field :scope, :string
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :lot, CreditLot

    timestamps()
  end
end
