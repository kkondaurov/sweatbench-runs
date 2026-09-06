defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Groups.payment_reconciliation(payment_operation_id) do
      {:ok, payment} ->
        json(conn, %{data: payment})

      {:error, "operation_not_found"} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
