defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  def show(conn, %{"payment_operation_id" => payment_id}) do
    case GroupStay.Payments.statement(payment_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, code} ->
        status = if code == "operation_not_found", do: 404, else: 422
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end
end
