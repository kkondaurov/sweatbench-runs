defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.get_payment(payment_operation_id) do
      {:ok, payment} ->
        json(conn, %{data: payment})

      {:error, %{code: "operation_not_found"}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      {:error, %{code: code}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
