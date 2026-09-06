defmodule GroupStay.Finance.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_events" do
    field :posted_on, :date
    field :operation_id, :string
    field :property_id, :string
    field :kind, :string
    field :classification, :string
    field :amount_cents, :integer
    field :lot_source_operation_id, :string
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :posted_on,
      :operation_id,
      :property_id,
      :kind,
      :classification,
      :amount_cents,
      :lot_source_operation_id,
      :expires_on
    ])
    |> validate_required([:posted_on, :kind, :classification, :amount_cents])
  end
end
