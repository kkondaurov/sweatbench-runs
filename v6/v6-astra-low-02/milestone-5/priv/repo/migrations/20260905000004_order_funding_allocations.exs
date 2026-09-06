defmodule GroupStay.Repo.Migrations.OrderFundingAllocations do
  use Ecto.Migration
  import Ecto.Query

  defmodule GroupRow do
    use Ecto.Schema
    @primary_key {:group_id, :string, autogenerate: false}
    schema "groups" do
      field(:funding_allocations, {:array, :map}, default: [])
    end
  end

  def up do
    # Before transfers, each payment belongs to one group. Preserve each group's
    # existing order; no cross-group ordering existed or was observable yet.
    Enum.reduce(repo().all(from(g in GroupRow, order_by: g.group_id)), 0, fn group, last ->
      {slices, last} =
        Enum.map_reduce(group.funding_allocations, last, fn slice, n ->
          {Map.put(slice, "allocation_order", n + 1), n + 1}
        end)

      repo().update!(Ecto.Changeset.change(group, funding_allocations: slices))
      last
    end)
  end

  def down do
    for group <- repo().all(GroupRow) do
      slices = Enum.map(group.funding_allocations, &Map.delete(&1, "allocation_order"))
      repo().update!(Ecto.Changeset.change(group, funding_allocations: slices))
    end
  end
end
