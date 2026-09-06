defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, %{"guest_id" => guest_id}) do
    render(conn, :show, credit: Deposits.guest_credit(guest_id, on_date(conn)))
  end

  # Expiry is reported as of the `on` query parameter when it carries a
  # usable date; otherwise the current UTC date is used.
  defp on_date(conn) do
    case conn.query_params["on"] do
      nil -> Date.utc_today()
      value -> parse_date(value) || Date.utc_today()
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil
end
