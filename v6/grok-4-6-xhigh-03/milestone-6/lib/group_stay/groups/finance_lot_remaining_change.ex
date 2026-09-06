defmodule GroupStay.Groups.FinanceLotRemainingChange do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_lot_remaining_changes" do
    field :credit_lot_id, :binary_id
    field :posting_date, :date
    field :delta_cents, :integer
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [:credit_lot_id, :posting_date, :delta_cents, :operation_id])
    |> validate_required([:credit_lot_id, :posting_date, :delta_cents])
  end
end
