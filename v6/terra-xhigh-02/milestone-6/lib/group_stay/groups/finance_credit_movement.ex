defmodule GroupStay.Groups.FinanceCreditMovement do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_credit_movements" do
    field :kind, :string
    field :amount_cents, :integer
    field :posted_on, :date

    timestamps(type: :utc_datetime)
  end

  @kinds ["issued", "expired", "consumed", "revoked", "absorbed"]

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:kind, :amount_cents, :posted_on])
    |> validate_required([:kind, :amount_cents, :posted_on])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, not_equal_to: 0)
  end
end
