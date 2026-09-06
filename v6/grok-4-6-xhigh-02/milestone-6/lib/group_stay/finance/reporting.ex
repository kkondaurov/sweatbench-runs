defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :opening_liability_cents, :integer
    field :opening_cash, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [
      :id,
      :starts_on,
      :start_operation_id,
      :opening_liability_cents,
      :opening_cash
    ])
    |> validate_required([
      :id,
      :starts_on,
      :start_operation_id,
      :opening_liability_cents,
      :opening_cash
    ])
    |> unique_constraint(:id, name: :finance_reporting_pkey)
    |> unique_constraint(:start_operation_id)
  end
end
