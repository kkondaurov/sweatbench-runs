defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One finance movement posted by an applied partner operation.

  Cash movements carry the property where the cash is held or settled;
  credit movements are company-wide and may reference the affected lot.
  The posting date is the latest of the operation's `occurred_on`, the
  reporting `starts_on`, and the day after the reporting cutoff at commit
  time. `late` marks movements whose posting date was moved forward by a
  period close.
  """

  use Ecto.Schema

  alias GroupStay.Groups.CreditLot

  schema "finance_movements" do
    field :posting_date, :date
    field :scope, :string
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :late, :boolean, default: false

    belongs_to :lot, CreditLot

    timestamps()
  end
end
