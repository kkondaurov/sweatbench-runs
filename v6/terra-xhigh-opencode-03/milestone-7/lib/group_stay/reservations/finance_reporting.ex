defmodule GroupStay.Reservations.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :closed_through_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:starts_on, :start_operation_id, :closed_through_on])
    |> validate_required([:starts_on, :start_operation_id])
    |> unique_constraint(:start_operation_id)
  end
end
