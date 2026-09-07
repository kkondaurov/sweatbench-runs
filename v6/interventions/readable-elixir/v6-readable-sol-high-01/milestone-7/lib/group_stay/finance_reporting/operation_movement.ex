defmodule GroupStay.FinanceReporting.OperationMovement do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_operation_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :late_adjustment, :boolean, default: false
    field :cash, :map
    field :credit, :map
    field :credit_lot_deltas, :map

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :operation_id,
      :posting_date,
      :late_adjustment,
      :cash,
      :credit,
      :credit_lot_deltas
    ])
    |> validate_required([
      :operation_id,
      :posting_date,
      :late_adjustment,
      :cash,
      :credit,
      :credit_lot_deltas
    ])
    |> unique_constraint(:operation_id)
  end
end
