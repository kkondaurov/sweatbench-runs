defmodule GroupStay.Groups.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string
  schema "rooms" do
    field :group_id, :string, primary_key: true
    field :position, :integer, primary_key: true
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
  end

  def changeset(room, attrs) do
    cast(room, attrs, [
      :group_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :lodging_cents,
      :deposit_due_cents,
      :status,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :group_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :lodging_cents,
      :deposit_due_cents,
      :status,
      :cash_paid_cents,
      :credit_paid_cents
    ])
  end
end
