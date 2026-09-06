defmodule GroupStay.Finance.Start do
  @moduledoc """
  The durable inception point of finance reporting. At most one row exists;
  the first applied `start_finance_reporting` operation inserts it, and the
  financial state immediately before that operation becomes the opening
  position on `starts_on`.
  """

  use Ecto.Schema

  @primary_key {:singleton, :integer, autogenerate: false}

  schema "finance_reporting_starts" do
    field :operation_id, :string
    field :starts_on, :date

    timestamps(type: :utc_datetime)
  end
end
