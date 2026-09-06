defmodule GroupStayWeb.OperationController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"operation_id" => operation_id}) do
    case Operations.get_operation(operation_id) do
      {:ok, result} -> json(conn, %{data: result})
      {:error, :operation_not_found} -> not_found(conn)
    end
  end

  def payment(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.get_payment(payment_operation_id) do
      {:ok, payment} -> json(conn, %{data: payment})
      {:error, :operation_not_found} -> not_found(conn)
      {:error, :payment_not_reconcilable} -> not_reconcilable(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "operation_not_found"}})
  end

  defp not_reconcilable(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "payment_not_reconcilable"}})
  end
end
