defmodule GroupStay.Accounting.LegacyFundingMove do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "legacy_funding_moves" do
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :origin_group, Group, foreign_key: :origin_group_id

    timestamps()
  end
end
