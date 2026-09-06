defmodule GroupStay.Reporting.FinanceEvent do
  @moduledoc """
  One finance movement recorded by an applied partner operation. Cash-scope
  events carry the property whose held cash moved; credit-scope events feed the
  company-wide liability bucket. Amounts are signed within their
  classification (a reversal such as a charged-back refund is a negative
  refund next to a positive charged-back amount).

  `credit_lot_id` and `lot_expires_on` (denormalized) let reads separate
  revocations that reduced liability from removals that happened after the
  lot expired, and keep recorded expiry events out of the derived day-by-day
  expiry pool. `late_adjustment` marks movements whose posting date was moved
  forward by a period close; they report into the `late_adjustments` block
  instead of the ordinary day movements.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @scopes ["cash", "credit"]
  @cash_classifications [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]
  @credit_classifications ["issued", "expired", "consumed", "revoked", "absorbed"]

  schema "finance_events" do
    field :scope, :string
    field :classification, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :posting_date, :date
    field :credit_lot_id, :integer
    field :lot_expires_on, :date
    field :late_adjustment, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  def classifications(scope) do
    case scope do
      "cash" -> @cash_classifications
      "credit" -> @credit_classifications
    end
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :scope,
      :classification,
      :property_id,
      :amount_cents,
      :posting_date,
      :credit_lot_id,
      :lot_expires_on,
      :late_adjustment
    ])
    |> validate_required([:scope, :classification, :amount_cents, :posting_date])
    |> validate_inclusion(:scope, @scopes)
    |> validate_classification()
  end

  defp validate_classification(changeset) do
    validate_change(changeset, :scope, fn :scope, scope ->
      if get_field(changeset, :classification) in classifications(scope) do
        []
      else
        [scope: {"has an unknown classification", []}]
      end
    end)
  end
end
