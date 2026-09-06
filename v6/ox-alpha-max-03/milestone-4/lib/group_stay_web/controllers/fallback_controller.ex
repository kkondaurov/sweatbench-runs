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

  def call(conn, {:error, :payment_not_reconcilable}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "payment_not_reconcilable"}})
  end
end
