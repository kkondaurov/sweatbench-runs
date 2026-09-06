defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  def show(conn, %{"payment_operation_id" => operation_id}) do
    case GroupStay.Operations.payment_statement(operation_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})

      :not_reconcilable ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})
    end
  end
end
