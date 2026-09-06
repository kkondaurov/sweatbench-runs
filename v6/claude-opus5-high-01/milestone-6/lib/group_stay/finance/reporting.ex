defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The single row that says finance reporting has started, and from which date.

  `singleton` is always zero and carries a unique index, so the first applied
  `start_finance_reporting` operation is the only one that can create it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting" do
    field :singleton, :integer, default: 0
    field :starts_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:singleton, :starts_on, :operation_id]

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:singleton)
  end
end
