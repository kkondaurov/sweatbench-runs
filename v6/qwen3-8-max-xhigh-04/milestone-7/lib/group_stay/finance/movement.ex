defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One reported finance effect of an applied partner operation.

  Movements are committed in the same transaction as the operation's domain
  changes, so rejected operations leave no reporting movement and durable
  retries never report a movement twice. `posted_on` is the latest of the
  operation's `occurred_on`, the reporting `starts_on`, and the day after the
  latest period close cutoff at the moment the operation commits; all finance
  effects of one operation use the same posting date. An operation keeps the
  posting date chosen when it commits; a later close never moves it again.

  `late` marks movements whose posting date was moved forward by a close.
  They are reported in the day's `late_adjustments` block instead of its
  ordinary movement columns.

  Cash movements carry the property where the cash is held or settled, so
  corrections follow the affected cash instead of returning to the payment's
  original property. Credit movements are company-wide and reference the
  affected lot where one exists.

  Classifications:

  - cash: `received`, `transferred_in`, `transferred_out`, `refunded`,
    `retained`, `converted_to_credit`, `reduced`, `charged_back`;
  - credit, reported: `issued`, `expired`, `consumed`, `revoked`, `absorbed`;
  - credit, internal: `applied`, `restored` — these track changes to a lot's
    remaining balance so expiry without a partner operation can be derived at
    reading time; they are not report movements.
  """

  use Ecto.Schema

  alias GroupStay.Credit.Lot

  schema "finance_movements" do
    field :operation_id, :string
    field :posted_on, :date
    field :kind, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late, :boolean, default: false

    belongs_to :credit_lot, Lot, type: :binary_id

    timestamps(type: :utc_datetime)
  end
end
