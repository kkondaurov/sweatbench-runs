defmodule GroupStay.FinanceCreditMovement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_movements" do
    field :operation_id, :string
    field :post_date, :date
    field :intended_post_date, :date
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :operation_id,
      :post_date,
      :intended_post_date,
      :issued_cents,
      :expired_cents,
      :consumed_cents,
      :revoked_cents,
      :absorbed_cents
    ])
    |> validate_required([:operation_id, :post_date])
    |> unique_constraint(:operation_id)
  end
end
