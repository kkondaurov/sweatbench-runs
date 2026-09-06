defmodule GroupStay.Finance.CashMovement do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.PartnerOperation

  @fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

  schema "finance_cash_movements" do
    belongs_to :partner_operation, PartnerOperation
    field :posting_on, :date
    field :property_id, :string
    Enum.each(@fields, &field(&1, :integer, default: 0))
  end

  def fields, do: @fields

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:partner_operation_id, :posting_on, :property_id | @fields])
    |> validate_required([:partner_operation_id, :posting_on, :property_id | @fields])
    |> unique_constraint([:partner_operation_id, :property_id])
  end
end
