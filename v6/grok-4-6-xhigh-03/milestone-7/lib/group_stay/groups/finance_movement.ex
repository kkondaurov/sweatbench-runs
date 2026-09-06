defmodule GroupStay.Groups.FinanceMovement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_movements" do
    field :posting_date, :date
    field :book, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :operation_id, :string
    field :late_adjustment, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :posting_date,
      :book,
      :property_id,
      :classification,
      :amount_cents,
      :operation_id,
      :late_adjustment
    ])
    |> validate_required([:posting_date, :book, :classification, :amount_cents])
  end
end
