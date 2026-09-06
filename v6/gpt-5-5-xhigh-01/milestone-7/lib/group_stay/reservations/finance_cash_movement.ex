defmodule GroupStay.Reservations.FinanceCashMovement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :movement_type, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(cash_movement, attrs) do
    cash_movement
    |> cast(attrs, [
      :operation_id,
      :posting_date,
      :property_id,
      :movement_type,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([
      :operation_id,
      :posting_date,
      :property_id,
      :movement_type,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_change(:amount_cents, fn :amount_cents, amount_cents ->
      if amount_cents == 0, do: [amount_cents: "must be non-zero"], else: []
    end)
  end
end
