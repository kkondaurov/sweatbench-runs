defmodule GroupStay.Finance.Event do
  @moduledoc """
  One reporting movement posted by an operation processed after finance
  reporting started.

  Cash events carry the property whose held cash moved; credit events are
  company-wide and carry no property. `amount_cents` is a signed net amount
  within its named classification: a normal refund posts positive
  `refunded`, reversing one posts negative `refunded` together with
  positive `charged_back`.

  `late` marks movements whose posting date was moved forward by a
  period close; they surface in the daily report's `late_adjustments`
  block in addition to the day's ordinary movements.
  """

  use Ecto.Schema

  schema "finance_events" do
    field :posting_date, :date
    field :kind, :string
    field :classification, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :source_operation_id, :string
    field :source_id, :string
    field :late, :boolean, default: false

    timestamps()
  end
end
