defmodule GroupStay.Finance.OpeningCreditLot do
  @moduledoc """
  The unused balance of one credit lot at the reporting inception point, for
  lots that had not yet expired. These balances are part of the opening
  liability and expire on the day after their lot's `expires_on` unless
  post-inception movements consume or revoke them first.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_opening_credit_lots" do
    field :remaining_cents, :integer, default: 0
    field :expires_on, :date

    belongs_to :reporting, GroupStay.Finance.Reporting
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end
end
