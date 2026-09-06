defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Groups.get_payment(payment_operation_id) do
      {:ok, payment} -> json(conn, %{"data" => payment})
      :not_found -> not_found(conn)
      {:error, :not_reconcilable} -> not_reconcilable(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => %{"code" => "operation_not_found"}})
  end

  defp not_reconcilable(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "payment_not_reconcilable"}})
  end
end
