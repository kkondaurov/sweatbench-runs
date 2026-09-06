defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Operations.parse_as_of(Map.get(params, "on")) do
      {:ok, as_of} ->
        case Operations.get_guest_credit(guest_id, as_of) do
          {:ok, credit} ->
            json(conn, %{data: credit})

          {:error, %{code: code}} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: code}})
        end

      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
