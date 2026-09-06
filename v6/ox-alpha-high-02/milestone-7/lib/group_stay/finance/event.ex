defmodule GroupStay.Finance.Event do
  @moduledoc """
  One finance movement recorded while reporting is active.

  Cash rows are attributed to a property; credit rows are company-wide.
  Amounts follow the report's sign conventions: positive for cash entering
  a classification, negative when an earlier classification is reversed.
  Internal classifications (applied) never appear in reports.
  """

  use Ecto.Schema

  schema "finance_events" do
    field :posted_on, :date
    field :scope, :string
    field :classification, :string
    field :property_id, :string
    field :amount_cents, :integer
    # True when a finance period close moved this event's posting date
    # forward to the first open day.
    field :posted_after_close, :boolean, default: false

    timestamps()
  end
end
