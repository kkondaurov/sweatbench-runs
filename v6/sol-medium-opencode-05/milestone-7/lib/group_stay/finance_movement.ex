defmodule GroupStay.FinanceMovement do
  use Ecto.Schema
  import Ecto.Changeset

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  schema "finance_movements" do
    field :posting_date, :date
    field :late_adjustment, :boolean, default: false
    field :operation_id, :string
    field :property_id, :string
    field :received_cents, :integer, default: 0
    field :transferred_in_cents, :integer, default: 0
    field :transferred_out_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :issued_cents, :integer, default: 0
    field :expired_cents, :integer, default: 0
    field :consumed_cents, :integer, default: 0
    field :revoked_cents, :integer, default: 0
    field :absorbed_cents, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  def changeset(movement, attrs) do
    movement
    |> cast(
      attrs,
      [:posting_date, :late_adjustment, :operation_id, :property_id] ++
        @cash_fields ++ @credit_fields
    )
    |> validate_required([:posting_date, :operation_id])
  end
end
