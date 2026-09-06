defmodule GroupStayWeb.GroupController do
  @moduledoc """
  Reads a single group reservation with its rooms and deposit totals.
  """

  use GroupStayWeb, :controller

  def show(conn, %{"group_id" => group_id}) do
    case GroupStay.Groups.fetch_group(group_id) do
      {:ok, group} ->
        json(conn, %{"data" => GroupStay.Groups.group_data(group)})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "group_not_found"}})
    end
  end
end
