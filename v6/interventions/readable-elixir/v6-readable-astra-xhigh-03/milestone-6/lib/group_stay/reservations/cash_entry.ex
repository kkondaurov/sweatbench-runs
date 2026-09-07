defmodule GroupStay.Reservations.CashEntry do
  @moduledoc """
  An immutable accounting fact reported by a partner operation.

  Payments increase held cash. Refunds and retentions move held cash into its
  final disposition. Credit conversions move cash into credit backing without
  counting it as a refund or retention. Unpaid requirements produce no entries.
  Reductions and chargebacks remove cash; negative settlement entries on a
  chargeback reclassify history without undoing the original accounting fact.
  Operation identifiers link entries to the submitted operation. The operation
  journal enforces idempotency: one operation may produce several accounting
  entries, and entries from earlier releases predate that journal.
  """
  use Ecto.Schema

  schema "cash_entries" do
    field :group_id, :string
    field :operation_id, :string
    field :occurred_on, :date

    field :kind, Ecto.Enum,
      values: [:payment, :refund, :retention, :credit_conversion, :reduction, :chargeback]

    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def record(_group_id, _operation, _occurred_on, _kind, 0), do: :ok

  def record(group_id, operation, occurred_on, kind, amount) do
    GroupStay.Repo.insert!(%__MODULE__{
      group_id: group_id,
      operation_id: operation["operation_id"],
      occurred_on: occurred_on,
      kind: kind,
      amount_cents: amount
    })
  end
end
