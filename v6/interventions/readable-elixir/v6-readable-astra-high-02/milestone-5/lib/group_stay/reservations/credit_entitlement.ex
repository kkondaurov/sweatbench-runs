defmodule GroupStay.Reservations.CreditEntitlement do
  @moduledoc """
  The immutable credit value attributable to converted payment principal in a lot.
  Running-total rounding makes entitlements sum exactly to the issued credit. This
  provenance is used only for revocation: spending within a lot remains fungible.
  """
  use Ecto.Schema

  schema "credit_entitlements" do
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
