defmodule GroupStay.Groups do
  @moduledoc """
  Reads groups, returning them with their rooms in their original order.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  import Ecto.Query

  @doc """
  Returns whether a group with the given partner identifier exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  @doc """
  Fetches a group by its partner identifier. Returns `:not_found` or
  `{:ok, %{group: group, rooms: rooms}}` with rooms in their original order.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :not_found
  def fetch(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        rooms =
          Repo.all(
            from r in Room,
              where: r.group_id == ^group.id,
              order_by: [asc: r.position]
          )

        {:ok, %{group: group, rooms: rooms}}
    end
  end
end
