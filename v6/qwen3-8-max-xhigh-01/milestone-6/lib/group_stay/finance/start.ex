defmodule GroupStay.Finance.Start do
  @moduledoc """
  The durable inception point of finance reporting.

  At most one start is ever applied; it is inserted under a fixed primary key
  so concurrent starts cannot both commit. The start carries the company-wide
  credit liability of the opening position captured immediately before the
  start operation was processed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = start, attrs) do
    start
    |> cast(attrs, [:id, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
    # The fixed primary key doubles as the uniqueness guard: a concurrent
    # start that loses the race is turned into a changeset error instead of
    # raising.
    |> unique_constraint(:id, name: "finance_reporting_starts_id_index")
  end
end
