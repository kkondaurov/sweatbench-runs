defmodule GroupStay.Finance.CreditMovement do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.PartnerOperation

  @fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  schema "finance_credit_movements" do
    belongs_to :partner_operation, PartnerOperation
    field :posting_on, :date
    Enum.each(@fields, &field(&1, :integer, default: 0))
  end

  def fields, do: @fields

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:partner_operation_id, :posting_on | @fields])
    |> validate_required([:partner_operation_id, :posting_on | @fields])
    |> unique_constraint(:partner_operation_id)
  end
end
