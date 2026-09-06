defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  def show(conn, %{"payment_operation_id" => operation_id}) do
    case GroupStay.Reservations.Payments.statement(operation_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, "operation_not_found" = code} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: code}})

      {:error, code} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: code}})
    end
  end
end
