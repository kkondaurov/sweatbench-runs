defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case GroupStay.payment_reconciliation(payment_operation_id) do
      {:ok, payment} ->
        json(conn, %{"data" => payment})

      {:error, :operation_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      {:error, :payment_not_reconcilable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "payment_not_reconcilable"}})
    end
  end
end
