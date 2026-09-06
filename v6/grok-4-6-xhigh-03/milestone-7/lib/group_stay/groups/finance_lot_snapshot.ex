defmodule GroupStay.Groups.FinanceLotSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_lot_snapshots" do
    field :credit_lot_id, :binary_id
    field :remaining_cents, :integer
    field :expires_on, :date
    field :expiry_posting_date, :date
    field :expiry_late, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :credit_lot_id,
      :remaining_cents,
      :expires_on,
      :expiry_posting_date,
      :expiry_late
    ])
    |> validate_required([:credit_lot_id, :remaining_cents, :expires_on])
    |> unique_constraint(:credit_lot_id)
  end
end
