defmodule GroupStay.Groups.CreditExpirySchedule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:credit_lot_id, :integer, autogenerate: false}
  schema "credit_expiry_schedules" do
    field :posting_on, :date
    field :amount_cents, :integer
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:credit_lot_id, :posting_on, :amount_cents])
    |> validate_required([:credit_lot_id, :posting_on, :amount_cents])
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
  end
end
