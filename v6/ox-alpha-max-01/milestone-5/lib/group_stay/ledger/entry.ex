defmodule GroupStay.Ledger.Entry do
  @moduledoc """
  An accounting fact applied to a group's deposit.

  Kinds:

  - `payment` — cash applied to an active group's outstanding deposit;
  - `refund` — cash returned to the partner on cancellation;
  - `retention` — cash kept by the hotel on a non-refundable cancellation;
  - `credit_conversion` — cash neither refunded nor retained because the
    guest chose hotel credit; it moves from held cash to converted credit;
  - `reduction` — a provider correction shrinking one recorded payment's
    held cash, reopening the outstanding deposit by that amount;
  - `chargeback` — cash reversed by a provider chargeback of one payment.

  Settlement and correction facts carry the `operation_id` of the payment
  they dispose of; facts from before durable operation records have none.
  GroupStay records these facts; payment providers move the money.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(payment refund retention credit_conversion reduction chargeback)

  schema "ledger_entries" do
    belongs_to :group, GroupStay.Groups.Group
    field :kind, :string
    field :amount_cents, :integer
    field :operation_id, :string

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :kind, :amount_cents, :operation_id])
    |> validate_required([:group_id, :kind, :amount_cents])
    |> validate_inclusion(:kind, @kinds)
  end
end
