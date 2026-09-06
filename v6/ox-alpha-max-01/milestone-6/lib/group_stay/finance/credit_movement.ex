defmodule GroupStay.Finance.CreditMovement do
  @moduledoc """
  One signed hotel-credit movement, posted against a single lot.

  Report columns are issued, expired, consumed, revoked, and absorbed — each
  positive when liability leaves or enters per the daily-report contract. Two
  internal kinds carry no liability change of their own: `applied` records
  credit redeemed into active rooms (moving from available to applied) and
  `restored` records credit returned to an unexpired lot's available balance.
  Both exist so expiry can be derived exactly for any date.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_movements" do
    field :posting_date, :date
    field :credit_lot_id, :id
    field :kind, :string
    field :amount_cents, :integer

    timestamps()
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:posting_date, :credit_lot_id, :kind, :amount_cents])
    |> validate_required([:posting_date, :credit_lot_id, :kind, :amount_cents])
  end
end
