defmodule GroupStay.Reservations.FinanceCreditExpiryAdjustment do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.FinanceCreditExpirySchedule

  schema "finance_credit_expiry_adjustments" do
    belongs_to :credit_expiry_schedule, FinanceCreditExpirySchedule
    field :operation_id, :string
    field :posting_date, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(adjustment, attributes) do
    adjustment
    |> cast(attributes, [
      :credit_expiry_schedule_id,
      :operation_id,
      :posting_date,
      :amount_cents
    ])
    |> validate_required([
      :credit_expiry_schedule_id,
      :operation_id,
      :posting_date,
      :amount_cents
    ])
    |> validate_number(:amount_cents, not_equal_to: 0)
  end
end
