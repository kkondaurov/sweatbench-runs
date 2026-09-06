defmodule GroupStay.CashDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "cash_dispositions" do
    belongs_to :funding, GroupStay.Funding
    field :property_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [
      :funding_id,
      :property_id,
      :refunded_cents,
      :retained_cents,
      :converted_cents,
      :reduced_cents,
      :charged_back_cents
    ])
    |> validate_required([:funding_id, :property_id])
  end
end
