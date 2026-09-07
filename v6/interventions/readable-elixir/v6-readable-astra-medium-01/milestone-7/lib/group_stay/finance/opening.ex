defmodule GroupStay.Finance.Opening do
  @moduledoc "The singleton opening position, captured inside the first start operation's transaction."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_opening" do
    field :starts_on, :date
    field :closed_through, :date
    field :cash, :map
    field :credit_liability_cents, :integer
  end
end
