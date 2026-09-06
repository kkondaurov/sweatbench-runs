defmodule GroupStay.Reporting.Movement do
  @moduledoc """
  One finance effect of an operation processed after reporting started,
  journaled for the daily report.

  `scope` is `"cash"` or `"credit"`. Cash rows carry the `property_id` the
  affected cash is held in or was settled in; credit rows are company-wide
  (`property_id` nil) and carry the `lot_id` they belong to when one exists.

  `kind` is a report classification (`received`, `transferred_in`,
  `transferred_out`, `refunded`, `retained`, `converted_to_credit`,
  `reduced`, `charged_back` for cash; `issued`, `expired`, `consumed`,
  `revoked`, `absorbed` for credit) or an internal credit kind with no
  report column (`applied`, `returned`, `clawback_removed`) that exists only
  so expiry can be simulated from the journal.
  """

  use Ecto.Schema

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)
  @internal_credit_kinds ~w(applied returned clawback_removed)

  schema "finance_movements" do
    field :posting_on, :date
    field :scope, :string
    field :kind, :string
    field :property_id, :string
    field :lot_id, :integer
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def cash_kinds, do: @cash_kinds
  def credit_kinds, do: @credit_kinds
  def internal_credit_kinds, do: @internal_credit_kinds
end
