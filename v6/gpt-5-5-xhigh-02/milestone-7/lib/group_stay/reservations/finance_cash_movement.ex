defmodule GroupStay.Reservations.FinanceCashMovement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :late_adjustment, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    operation_id
    posting_date
    property_id
    received_cents
    transferred_in_cents
    transferred_out_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
    late_adjustment
  )a

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, @fields)
    |> validate_required([:operation_id, :posting_date, :property_id])
  end
end
