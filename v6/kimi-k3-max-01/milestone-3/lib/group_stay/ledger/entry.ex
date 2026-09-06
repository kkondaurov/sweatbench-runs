defmodule GroupStay.Ledger.Entry do
  @moduledoc """
  An accounting fact recorded for a group deposit. Entries are never updated
  or deleted; the finance totals are derived from them.

  Kinds:

    * `cash_received` - cash applied to a group's deposit;
    * `cash_refunded` - held cash returned when a refundable group is cancelled;
    * `cash_retained` - held cash kept when a non-refundable group is cancelled;
    * `cash_converted_to_credit` - held cash converted to hotel credit when a
      refundable group is cancelled with `refund_method: "hotel_credit"`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @kinds ~w(cash_received cash_refunded cash_retained cash_converted_to_credit)

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
    |> validate_number(:amount_cents, greater_than: 0)
    |> assoc_constraint(:group)
  end
end
