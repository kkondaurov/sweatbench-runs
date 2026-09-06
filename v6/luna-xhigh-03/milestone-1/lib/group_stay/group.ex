defmodule GroupStay.Group do
  @moduledoc "The persisted representation of a group reservation."

  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__, :rooms_json]}

  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :rooms_json, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :revision, :integer
  end
end
