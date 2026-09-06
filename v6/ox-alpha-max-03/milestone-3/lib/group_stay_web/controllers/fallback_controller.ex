defmodule GroupStayWeb.FallbackController do
  use GroupStayWeb, :controller

  def call(conn, {:error, :group_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "group_not_found"}})
  end

  def call(conn, {:error, :operation_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "operation_not_found"}})
  end
end
