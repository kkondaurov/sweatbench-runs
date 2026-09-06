defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Payments

  @moduledoc """
  Reconciles one durably recorded cash payment: the current disposition of
  its cash across held, refunded, retained, converted, reduced, and
  charged-back amounts. Reading a statement never changes state.
  """

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Payments.statement(payment_operation_id) do
      {:ok, data} ->
        json(conn, %{"data" => string_keys(data)})

      {:error, :operation_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      {:error, :payment_not_reconcilable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "payment_not_reconcilable"}})
    end
  end

  defp string_keys(data) do
    Map.new(data, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
