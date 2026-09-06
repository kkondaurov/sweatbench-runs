defmodule GroupStay.FinanceJournal do
  use Ecto.Schema

  alias GroupStay.{CreditLot, Payment}

  @moduledoc """
  A signed finance movement produced by an applied partner operation.

  Cash-side entries (`received`, `transferred_in`, `transferred_out`,
  `refunded`, `retained`, `converted`, `reduced`, `charged_back`) carry a
  `property_id`; credit-side entries (`issued`, `expired`, `consumed`,
  `revoked`, `absorbed`) carry `lot_id` where meaningful and leave
  `property_id` null.

  Rows are written in the same transaction as the operation's domain
  changes and are durably idempotent: a durable retry never writes them
  twice. `durable_operation_id` is backfilled after the operation's durable
  record is inserted and separates opening contributions from movements.
  """

  @foreign_key_type :binary_id

  schema "finance_journal" do
    field :operation_id, :string
    field :durable_operation_id, :integer
    field :posting_date, :date
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer

    belongs_to :payment, Payment
    belongs_to :credit_lot, CreditLot

    timestamps()
  end
end
