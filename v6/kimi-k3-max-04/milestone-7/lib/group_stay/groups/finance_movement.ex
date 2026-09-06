defmodule GroupStay.Groups.FinanceMovement do
  @moduledoc """
  One signed finance effect posted on a reporting date. `scope` is `"cash"`
  or `"credit"`; cash movements carry the property where the cash is held or
  was settled, credit movements are company-wide (`property_id` nil).

  Cash `kind`s: `"received"`, `"transferred_in"`, `"transferred_out"`,
  `"refunded"`, `"retained"`, `"converted_to_credit"`, `"reduced"`,
  `"charged_back"`. Credit `kind`s: `"issued"`, `"expired"`, `"consumed"`,
  `"revoked"`, `"absorbed"`. Reversals are signed, so a refund reversed by a
  chargeback records negative `"refunded"` and positive `"charged_back"`.

  `late` flags a movement whose posting date was moved forward by a
  committed close: it reports in the current day's `late_adjustments` block
  instead of the ordinary `movements` columns. Balances use both.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_movements" do
    field :posting_date, :date
    field :scope, :string
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :late, :boolean

    timestamps()
  end
end
