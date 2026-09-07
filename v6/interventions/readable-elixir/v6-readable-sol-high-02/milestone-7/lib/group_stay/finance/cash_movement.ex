defmodule GroupStay.Finance.CashMovement do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @movement_fields [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :late_adjustment, :boolean, default: false
    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end

  def movement_fields, do: @movement_fields

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:operation_id, :posting_on, :property_id, :late_adjustment | @movement_fields])
    |> validate_required([
      :operation_id,
      :posting_on,
      :property_id,
      :late_adjustment | @movement_fields
    ])
    |> unique_constraint([:operation_id, :property_id])
  end
end
