defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit

  def show(conn, %{"guest_id" => guest_id} = params) do
    as_of = as_of_date(params["on"])
    json(conn, %{"data" => Credit.render(guest_id, as_of)})
  end

  defp as_of_date(nil), do: Date.utc_today()

  defp as_of_date(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> date
      {:error, _} -> Date.utc_today()
    end
  end
end
