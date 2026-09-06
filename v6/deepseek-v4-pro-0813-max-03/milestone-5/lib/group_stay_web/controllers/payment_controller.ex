defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Accounting

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Accounting.reconcile_payment(payment_operation_id) do
      {:ok, data} ->
        json(conn, %{data: data})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      :not_payment ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})
    end
  end
end
