defmodule GroupStay.Groups.FinanceCashMovement do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_cash_movements" do
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :posted_on, :date

    timestamps(type: :utc_datetime)
  end

  @kinds [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:property_id, :kind, :amount_cents, :posted_on])
    |> validate_required([:property_id, :kind, :amount_cents, :posted_on])
    |> validate_length(:property_id, min: 1)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, not_equal_to: 0)
  end
end
