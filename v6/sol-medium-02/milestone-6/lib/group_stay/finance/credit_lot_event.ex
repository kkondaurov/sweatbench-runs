defmodule GroupStay.Finance.CreditLotEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.PartnerOperation

  schema "finance_credit_lot_events" do
    belongs_to :partner_operation, PartnerOperation
    belongs_to :credit_lot, CreditLot
    field :posting_on, :date
    field :available_delta_cents, :integer
    field :applied_delta_cents, :integer
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :partner_operation_id,
      :credit_lot_id,
      :posting_on,
      :available_delta_cents,
      :applied_delta_cents
    ])
    |> validate_required([
      :partner_operation_id,
      :credit_lot_id,
      :posting_on,
      :available_delta_cents,
      :applied_delta_cents
    ])
    |> unique_constraint([:partner_operation_id, :credit_lot_id])
  end
end
