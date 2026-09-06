defmodule GroupStay.Reservations.FinanceCreditMovement do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :movement_type, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false

    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(credit_movement, attrs) do
    credit_movement
    |> cast(attrs, [
      :operation_id,
      :posting_date,
      :credit_lot_id,
      :movement_type,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([
      :operation_id,
      :posting_date,
      :movement_type,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_change(:amount_cents, fn :amount_cents, amount_cents ->
      if amount_cents == 0, do: [amount_cents: "must be non-zero"], else: []
    end)
  end
end
