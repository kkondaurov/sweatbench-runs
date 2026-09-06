defmodule GroupStay.Groups.FinanceMovement do
  @moduledoc """
  One finance effect of an operation processed after reporting started.

  `posted_on` is the operation's reporting posting date (the later of its
  `occurred_on` and reporting's `starts_on`). Amounts are stored in the display
  orientation of their report movement: positive when the named classification
  grows, so reversing an earlier refund stores a negative `refunded` amount
  alongside a positive `charged_back` amount.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "finance_movements" do
    field :posted_on, :date
    field :domain, :string
    field :classification, :string
    field :property_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
