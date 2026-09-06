defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Reservations.guest_credit(guest_id, report_date(params))})
  end

  defp report_date(%{"on" => value}) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> Date.utc_today()
    end
  end

  defp report_date(_params), do: Date.utc_today()
end
