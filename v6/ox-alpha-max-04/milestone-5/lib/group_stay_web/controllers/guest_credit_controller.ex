defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit
  alias GroupStayWeb.QueryDate

  @doc """
  Renders a guest's available hotel credit as of the `on` query date, one
  entry per unexpired lot with a remaining balance. Expired and exhausted
  lots are omitted.
  """
  def show(conn, %{"guest_id" => guest_id} = params) do
    case QueryDate.parse(params["on"]) do
      {:ok, as_of} ->
        json(conn, %{data: Credit.guest_credit(guest_id, as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
