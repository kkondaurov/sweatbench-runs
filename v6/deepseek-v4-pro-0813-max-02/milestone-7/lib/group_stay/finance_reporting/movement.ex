defmodule GroupStay.FinanceReporting.Movement do
  @moduledoc """
  One dated finance effect of an applied operation, or a credit lot lifecycle
  event, recorded after finance reporting has started.

  `category` is `cash` or `credit`. Cash rows carry a `property_id`;
  credit rows can carry a `lot_id`. `classification` names the movement
  column a row belongs to. Credit pool events use the internal
  `pool_apply`, `pool_restore`, and `pool_revoke` classifications and never
  appear directly in a report; they only decide how much of a lot expires
  on its expiry date.

  `late` marks a movement whose posting date was moved forward by a finance
  period close. Late movements appear in a report's `late_adjustments`
  block instead of its ordinary movement columns.
  """

  use Ecto.Schema

  schema "finance_movements" do
    field :category, :string
    field :classification, :string
    field :property_id, :string
    field :lot_id, :binary_id
    field :amount_cents, :integer
    field :posting_date, :date
    field :late, :boolean, default: false
  end
end
