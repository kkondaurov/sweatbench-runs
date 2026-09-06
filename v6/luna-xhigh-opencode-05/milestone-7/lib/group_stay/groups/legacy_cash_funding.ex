defmodule GroupStay.Groups.LegacyCashFunding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:group_id, :string, autogenerate: false}
  schema "legacy_cash_fundings" do
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
  end

  def changeset(funding, attrs) do
    cast(funding, attrs, [
      :group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
  end
end
