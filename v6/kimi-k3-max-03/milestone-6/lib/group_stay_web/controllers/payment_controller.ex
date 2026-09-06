defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.reconcile_payment(payment_operation_id) do
      :not_found ->
        conn
        |> put_status(:not_found)
        |> render(:not_found)

      :not_reconcilable ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:not_reconcilable)

      {:ok, payment} ->
        render(conn, :show, payment: payment)
    end
  end
end
