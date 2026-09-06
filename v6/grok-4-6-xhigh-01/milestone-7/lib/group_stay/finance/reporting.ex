defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :opening, :map
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:id, :starts_on, :start_operation_id, :opening, :period_end_on])
    |> validate_required([:id, :starts_on, :start_operation_id, :opening])
    |> unique_constraint(:id)
  end
end
