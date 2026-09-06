defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  action_fallback GroupStayWeb.FallbackController

  def show(conn, %{"group_id" => group_id}) do
    case Deposits.get_group(group_id) do
      nil -> {:error, :group_not_found}
      group -> render(conn, :show, group: group)
    end
  end
end
