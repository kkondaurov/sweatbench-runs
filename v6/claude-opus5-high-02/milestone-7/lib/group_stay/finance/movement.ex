defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One finance effect of one operation, stamped with the date it posts to.

  Movements are only ever inserted, so a report is an aggregation of the rows standing at the
  moment it is read and reading one changes nothing. A later submission simply adds rows, which is
  why it can change an already open report.

  `scope` says which balance the row belongs to:

    * `cash` - held cash at the property named by `property_id`;
    * `credit` - the company-wide hotel-credit liability;
    * `lot` - what one credit lot holds outside the rooms it is funding, which is what expires when
      the lot's `expires_on` passes. Lot rows carry no liability of their own: they are the record
      the report derives each lot's expiry from.

  `amount_cents` is the amount the report states for `kind`, signed the way the report states it: a
  chargeback that reverses an earlier refund records a negative `refunded` alongside a positive
  `charged_back`. `direction/1` turns that reported amount into the effect it has on the balance.

  `late` marks a row a period close pushed forward: it belongs to the day it posted to, but the
  report states it in that day's late adjustments rather than among its ordinary movements.

  The opening position is a row of kind `opening` posted the day before reporting starts, so that
  it counts towards every report's opening balance and is never itself a movement on a reported
  date.
  """

  use Ecto.Schema

  alias GroupStay.Finance.Movement

  @cash "cash"
  @credit "credit"
  @lot "lot"

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit
                 reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  # How each kind moves the balance it belongs to. Cash held grows when it is received or
  # transferred in and falls when it leaves the rooms it funded; liability grows when credit is
  # issued and falls when it leaves through expiry, consumption, revocation, or absorption.
  @directions %{
    "opening" => 1,
    "balance" => 1,
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1,
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  schema "finance_movements" do
    field :posting_date, :date
    field :scope, :string
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :late, :boolean, default: false

    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end

  def cash, do: @cash
  def credit, do: @credit
  def lot, do: @lot

  @doc """
  The cash movement columns a property's report states, in the order it states them.
  """
  def cash_kinds, do: @cash_kinds

  @doc """
  The credit movement columns the report states, in the order it states them.
  """
  def credit_kinds, do: @credit_kinds

  @doc """
  The effect a reported amount of this kind has on the balance it belongs to.
  """
  def direction(kind), do: Map.fetch!(@directions, kind)

  @doc """
  The signed effect a row has on its balance.
  """
  def balance_cents(%Movement{kind: kind, amount_cents: amount_cents}),
    do: direction(kind) * amount_cents
end
