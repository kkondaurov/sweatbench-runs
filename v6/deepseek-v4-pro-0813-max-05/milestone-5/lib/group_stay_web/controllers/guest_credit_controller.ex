defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  @doc """
  Returns a guest's available hotel credit and unexpired credit lots.
  Accepts an optional `on=YYYY-MM-DD` query parameter to report expiry as
  of a given date; the current UTC date is used when it is omitted.
  """
  def show(conn, params) do
    with {:ok, on} <- Groups.as_of(params) do
      json(conn, %{data: Groups.guest_credit(params["guest_id"], on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
