defmodule GroupStay.Finance.CreditMovement do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @movement_fields [
    :issued_cents,
    :expired_cents,
    :consumed_cents,
    :revoked_cents,
    :absorbed_cents
  ]

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :late_adjustment, :boolean, default: false
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0
  end

  def movement_fields, do: @movement_fields

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:operation_id, :posting_on, :late_adjustment | @movement_fields])
    |> validate_required([:operation_id, :posting_on, :late_adjustment | @movement_fields])
    |> unique_constraint(:operation_id)
  end
end
