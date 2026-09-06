defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations
  alias GroupStay.Payments

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.get_record(payment_operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      record ->
        if Payments.applied_cash_payment?(record) do
          json(conn, %{data: Payments.statement_payload(record)})
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{code: "payment_not_reconcilable"}})
        end
    end
  end
end
