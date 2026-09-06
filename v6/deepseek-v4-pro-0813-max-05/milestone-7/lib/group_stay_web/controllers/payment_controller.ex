defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  @doc """
  Returns the current dispositions of one durably recorded cash payment.

  A missing durable record is `404` with `operation_not_found`; a record
  that is not an applied cash payment is `422` with
  `payment_not_reconcilable`. Reading never changes state.
  """
  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Groups.payment_statement(payment_operation_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      :unreconcilable ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})
    end
  end
end
