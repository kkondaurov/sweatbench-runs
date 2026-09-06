defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_json, :string
    field :latest_closed_on, :date
  end
end
