defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit
  alias GroupStay.Operations

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Credit.available(guest_id, as_of(params))})
  end

  defp as_of(%{"on" => value}) do
    case Operations.parse_date(value) do
      {:ok, date} -> date
      :error -> Date.utc_today()
    end
  end

  defp as_of(_params), do: Date.utc_today()
end
