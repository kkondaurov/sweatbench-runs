defmodule GroupStay.Deposits.FinanceEvent do
  @moduledoc """
  One finance movement posted to the daily report.

  Cash events carry the `property_id` of the group whose rooms held, received,
  or settled the cash; credit events are company-wide and leave it null.
  `amount_cents` is stored with the sign the report displays: a normal refund
  stores a positive `refunded` amount while reversing that refund through a
  chargeback stores negative `refunded` and positive `charged_back` amounts.

  Credit expiry is not recorded as an event: it is derived from the credit
  lots themselves (see `GroupStay.Deposits.daily_report/1`) so a lot expiring
  without any partner operation on that date still shows its expiry.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @categories ~w(cash credit)

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)
  @kinds @cash_kinds ++ @credit_kinds

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_events" do
    field :posted_on, :date
    field :category, :string
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :operation_id, :string

    # For settlement movements, the payment operation whose cash moved.
    field :related_operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :posted_on,
      :category,
      :kind,
      :property_id,
      :amount_cents,
      :operation_id,
      :related_operation_id
    ])
    |> validate_required([:posted_on, :category, :kind, :amount_cents])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, not_equal_to: 0)
  end

  def kinds, do: @kinds
end
