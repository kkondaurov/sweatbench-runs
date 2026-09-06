defmodule GroupStayWeb.PaymentsController do
  use GroupStayWeb, :controller

  alias GroupStay.Payments

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Payments.reconcile(payment_operation_id) do
      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      :not_reconcilable ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "payment_not_reconcilable"}})

      {:ok, payment} ->
        json(conn, %{"data" => payment})
    end
  end
end
