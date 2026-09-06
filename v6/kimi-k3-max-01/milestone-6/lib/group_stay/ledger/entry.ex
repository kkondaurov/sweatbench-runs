defmodule GroupStay.Ledger.Entry do
  @moduledoc """
  An accounting fact recorded for a group deposit. Entries are never updated
  or deleted; the finance totals are derived from them.

  Kinds:

    * `cash_received` - cash applied to a group's deposit;
    * `cash_refunded` - held cash returned when a refundable group is cancelled;
    * `cash_retained` - held cash kept when a non-refundable group is cancelled;
    * `cash_converted_to_credit` - held cash converted to hotel credit when a
      refundable group is cancelled with `refund_method: "hotel_credit"`;
    * `cash_reduced` - held cash removed by a provider correction;
    * `cash_charged_back` - cash reversed by a chargeback.

  Reclassifications record a compensating pair of entries (a negative amount
  in the source kind and a positive amount in the target kind), so negative
  amounts only ever appear in such pairs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @kinds ~w(cash_received cash_refunded cash_retained cash_converted_to_credit cash_reduced
            cash_charged_back)

  schema "ledger_entries" do
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :kind, :amount_cents, :occurred_on])
    |> validate_required([:group_id, :kind, :amount_cents, :occurred_on])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, not_equal_to: 0)
    |> assoc_constraint(:group)
  end
end
