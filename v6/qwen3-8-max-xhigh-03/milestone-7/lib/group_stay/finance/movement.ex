defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One reported movement of held cash or credit liability. Movements are
  recorded in the same transaction as the applied operation that caused them.
  `natural_posting_date` is the later of the operation's `occurred_on` and
  the reporting `starts_on`; when that date falls inside a closed period, the
  movement posts instead to the first open day and becomes a late adjustment
  there. A movement keeps the posting date chosen when it commits.

  Cash movements carry the property where the cash is held or settled;
  corrections follow the affected cash rather than the payment's original
  property. Credit movements are company-wide; a `revoked` movement keeps its
  lot so the report can tell whether the revocation reduced liability before
  the lot expired.
  """

  use Ecto.Schema

  schema "finance_movements" do
    field :posting_date, :date
    field :natural_posting_date, :date
    field :scope, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :operation_id, :string

    belongs_to :lot, GroupStay.Credit.Lot, foreign_key: :lot_id

    timestamps(type: :utc_datetime)
  end
end
