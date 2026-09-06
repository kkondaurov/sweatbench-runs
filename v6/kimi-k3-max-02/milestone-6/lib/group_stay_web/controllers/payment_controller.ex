defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Groups.get_payment_statement(payment_operation_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      :not_reconcilable ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})
    end
  end
end
