defmodule GroupStay.Deposits.CreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    # The balance the lot carries towards its expiry date. Mutations driven by
    # operations dated before `expires_on` keep this equal to
    # `remaining_cents`; a clawback recovered on or after the expiry date only
    # reduces `remaining_cents`, so reports still show what actually expired.
    field :expiry_pending_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :issued_cents,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents,
      :expiry_pending_cents
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :issued_cents,
      :remaining_cents,
      :expires_on
    ])
    |> validate_number(:issued_cents, greater_than: 0)
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end

  def update_changeset(lot, attrs) do
    cast(lot, attrs, [:remaining_cents, :unrecovered_clawback_cents, :expiry_pending_cents])
  end
end
