defmodule GroupStay.Finance.Inception do
  @moduledoc "The immutable opening position, captured at the reporting commit boundary."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_inception" do
    field :starts_on, :date
    field :cash, :map
    field :credit_liability_cents, :integer
  end
end
