defmodule GroupStay.Groups do
  @moduledoc """
  The groups context: group reservations and the rooms they hold.
  """

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @doc """
  Returns the group identified by its partner group id, with rooms in their
  original order, or nil when no such group exists.
  """
  def get_with_rooms(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))
    end
  end
end
