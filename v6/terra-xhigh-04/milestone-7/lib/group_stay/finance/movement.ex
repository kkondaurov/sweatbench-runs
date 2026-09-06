defmodule GroupStay.Finance.Movement do
  @moduledoc false

  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :kind, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean

    timestamps(type: :utc_datetime)
  end
end
