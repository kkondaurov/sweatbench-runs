defmodule GroupStay.CreditExpirySchedule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "credit_expiry_schedules" do
    belongs_to :lot, GroupStay.CreditLot, primary_key: true
    field :expires_on, :date
    field :amount_cents, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:lot_id, :expires_on, :amount_cents])
    |> validate_required([:lot_id, :expires_on, :amount_cents])
  end
end
