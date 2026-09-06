defmodule GroupStay.Finance.Movement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :natural_posting_date, :date
    field :late, :boolean, default: false
    field :kind, :string
    field :property_id, :string
    field :lot_id, :string
    field :expires_on, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :operation_id,
      :posting_date,
      :natural_posting_date,
      :late,
      :kind,
      :property_id,
      :lot_id,
      :expires_on,
      :amount_cents
    ])
    |> validate_required([:posting_date, :kind, :amount_cents])
  end
end
