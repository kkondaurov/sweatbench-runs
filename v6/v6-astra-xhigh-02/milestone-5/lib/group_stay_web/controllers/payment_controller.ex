defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  def show(conn, %{"payment_operation_id" => id}) do
    case GroupStay.Reservations.Payments.statement(id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, %{code: code}} ->
        status = if code == "operation_not_found", do: :not_found, else: :unprocessable_entity
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end
end
