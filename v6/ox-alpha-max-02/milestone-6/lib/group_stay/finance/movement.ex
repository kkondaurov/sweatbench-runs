defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One classified finance movement, recorded when the operation that caused it
  is applied and attributed to its reporting posting date.

  Cash kinds - `received`, `transferred_in`, `transferred_out`, `refunded`,
  `retained`, `converted_to_credit`, `reduced`, `charged_back` - carry the
  `property_id` where the cash is held or was settled. Credit kinds -
  `issued`, `expired`, `consumed`, `revoked`, `absorbed` - are company-wide
  and name their `credit_lot_id`.

  Two additional lot-scoped kinds never surface in reports but track a lot's
  unused balance so its expiry can be reported on the right day even when no
  partner operation was submitted: `restored` (credit returned to a lot by a
  refundable settlement) and `applied` (credit drawn from a lot onto a group).
  Neither changes liability.

  Amounts are signed within their classification: positive in the normal
  direction (a received payment, an issued lot) and negative when a later
  operation reverses an earlier classification.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_movements" do
    field :posting_date, :date
    field :kind, :string
    field :property_id, :string
    field :credit_lot_id, :binary_id
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
