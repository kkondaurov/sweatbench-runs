defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable finance-reporting inception point.

  The first applied `start_finance_reporting` operation writes exactly one
  row: its `starts_on` date together with the opening credit liability as
  of `starts_on`, evaluated on the state of every operation committed
  before the start operation was processed. The opening held-cash position
  per property is not stored: it derives from the current room allocations
  minus every posted cash movement, because reporting posts each cash
  effect exactly once.
  """

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  @singleton_id 1

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_liability_cents, :integer

    timestamps()
  end

  def changeset(reporting, attrs) do
    reporting
    |> Ecto.Changeset.cast(attrs, [:starts_on, :opening_liability_cents])
    |> Ecto.Changeset.validate_required([:starts_on, :opening_liability_cents])
    |> Ecto.Changeset.validate_number(:opening_liability_cents, greater_than_or_equal_to: 0)
  end

  @doc "The singleton reporting state struct, or `nil` before reporting started."
  def one do
    GroupStay.Repo.get(__MODULE__, @singleton_id)
  end
end
