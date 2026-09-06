defmodule GroupStay.Reservations.FinanceCashMovement do
  use Ecto.Schema
  import Ecto.Changeset

  @amount_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:operation_id, :posting_on, :property_id | @amount_fields])
    |> validate_required([:operation_id, :posting_on, :property_id | @amount_fields])
  end
end
