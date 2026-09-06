defmodule GroupStay.Repo.Migrations.OrderRoomAllocations do
  use Ecto.Migration
  import Ecto.Query

  def up do
    for row <-
          repo().all(from(s in "room_accounts", select: %{group_id: s.group_id, data: s.data})) do
      data = if is_binary(row.data), do: Jason.decode!(row.data), else: row.data

      entries =
        data["entries"]
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} ->
          Map.put(entry, "order", [0, index])
        end)

      repo().update_all(from(s in "room_accounts", where: s.group_id == ^row.group_id),
        set: [data: Jason.encode!(Map.put(data, "entries", entries))]
      )
    end
  end

  def down, do: :ok
end
