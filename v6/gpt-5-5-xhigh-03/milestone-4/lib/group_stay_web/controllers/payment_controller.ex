defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Reservations.get_payment_reconciliation(payment_operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      {:error, :payment_not_reconcilable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})

      data ->
        json(conn, %{data: data})
    end
  end
end
