defmodule GroupStay.Finance.Entry do
  @moduledoc """
  An immutable opening balance or signed movement in the reporting journal.

  A property identifies cash; a nil property identifies company-wide credit.
  Entries commit with their operation's domain changes and durable receipt.
  Scheduled expiry entries can be offset by later entries when credit is redeemed,
  restored or revoked. No report read writes or consumes these entries.
  A late adjustment records a movement deferred by a close, independently of any
  later cutoff. Existing entries and their classifications never move again.
  """
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :posted_on, :date
    field :late_adjustment, :boolean, default: false
    field :property_id, :string

    field :classification, Ecto.Enum,
      values: [
        :opening_held_cents,
        :opening_liability_cents,
        :received_cents,
        :transferred_in_cents,
        :transferred_out_cents,
        :refunded_cents,
        :retained_cents,
        :converted_to_credit_cents,
        :reduced_cents,
        :charged_back_cents,
        :issued_cents,
        :expired_cents,
        :consumed_cents,
        :revoked_cents,
        :absorbed_cents
      ]

    field :amount_cents, :integer
  end
end
