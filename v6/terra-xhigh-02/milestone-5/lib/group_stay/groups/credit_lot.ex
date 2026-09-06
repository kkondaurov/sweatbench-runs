defmodule GroupStay.Groups.CreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
    field :expires_on, :date
    field :revision, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  def create_changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :unrecovered_clawback_cents,
      :expires_on,
      :revision
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :unrecovered_clawback_cents,
      :expires_on,
      :revision
    ])
    |> validate_length(:guest_id, min: 1)
    |> validate_length(:source_operation_id, min: 1)
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> validate_number(:unrecovered_clawback_cents, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than: 0)
  end

  def update_changeset(lot, attrs) do
    lot
    |> cast(attrs, [:remaining_cents, :unrecovered_clawback_cents])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> validate_number(:unrecovered_clawback_cents, greater_than_or_equal_to: 0)
    |> optimistic_lock(:revision)
  end
end
