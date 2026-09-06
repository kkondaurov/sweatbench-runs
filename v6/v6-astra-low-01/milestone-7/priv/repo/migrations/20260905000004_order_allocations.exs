defmodule GroupStay.Repo.Migrations.OrderAllocations do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Before transfers, each payment belongs to one group. Preserve each group's
    # existing allocation order; ordering unrelated groups cannot affect corrections.
    repo().all(from(g in GroupStay.Group, order_by: g.group_id))
    |> Enum.reduce(0, fn group, order ->
      {funding, order} =
        Enum.map_reduce(group.funding, order, fn entry, n ->
          {Map.put(entry, "allocation_order", n + 1), n + 1}
        end)

      repo().update!(Ecto.Changeset.change(group, funding: funding))
      order
    end)
  end

  def down, do: :ok
end
