defmodule GroupStay.Reservations.CreditLot do
  @moduledoc """
  Hotel credit issued by one refundable cancellation.

  `expires_on` is the first date the lot is unavailable. Amounts allocated to
  active groups are represented separately because their expiry is paused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(lot, attributes) do
    lot
    |> cast(attributes, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than: 0)
  end

  def balance_changeset(lot, remaining_cents) do
    lot
    |> change(remaining_cents: remaining_cents)
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end

  def clawback_changeset(lot, remaining_cents, unrecovered_cents) do
    lot
    |> change(
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: unrecovered_cents
    )
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> validate_number(:unrecovered_clawback_cents, greater_than_or_equal_to: 0)
  end
end
