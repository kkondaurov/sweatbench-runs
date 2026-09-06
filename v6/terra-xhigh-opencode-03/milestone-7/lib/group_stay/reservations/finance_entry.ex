defmodule GroupStay.Reservations.FinanceEntry do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.FinanceReporting

  @entry_kinds [
    "cash_opening",
    "cash_received",
    "cash_transferred_in",
    "cash_transferred_out",
    "cash_refunded",
    "cash_retained",
    "cash_converted_to_credit",
    "cash_reduced",
    "cash_charged_back",
    "credit_opening",
    "credit_issued",
    "credit_expired",
    "credit_consumed",
    "credit_revoked",
    "credit_absorbed",
    "credit_available_opening",
    "credit_available_issued",
    "credit_available_applied",
    "credit_available_restored",
    "credit_available_revoked"
  ]

  schema "finance_entries" do
    field :partner_operation_id, :string
    field :entry_index, :integer
    field :posting_on, :date
    field :kind, :string
    field :property_id, :string
    field :credit_lot_id, :binary_id
    field :expires_on, :date
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false

    belongs_to :reporting, FinanceReporting

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :reporting_id,
      :partner_operation_id,
      :entry_index,
      :posting_on,
      :kind,
      :property_id,
      :credit_lot_id,
      :expires_on,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([
      :reporting_id,
      :partner_operation_id,
      :entry_index,
      :posting_on,
      :kind,
      :amount_cents
    ])
    |> validate_inclusion(:kind, @entry_kinds)
    |> unique_constraint([:partner_operation_id, :entry_index])
  end
end
