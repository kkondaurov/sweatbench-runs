defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case OperationalCore.get_payment(payment_operation_id) do
      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      :not_reconcilable ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})

      {:ok, payment} ->
        json(conn, %{data: payment})
    end
  end
end
