defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"payment_operation_id" => operation_id}) do
    case Reservations.get_payment(operation_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, code} ->
        status = if code == "operation_not_found", do: :not_found, else: :unprocessable_entity
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end
end
