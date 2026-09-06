defmodule GroupStay.Bookings.CashDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CashSource, Group}

  schema "cash_dispositions" do
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :cash_source, CashSource
    belongs_to :group, Group, references: :group_id, type: :string
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:cash_source_id, :group_id, :kind, :amount_cents])
    |> validate_required([:cash_source_id, :group_id, :kind, :amount_cents])
  end
end
