defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credits

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Credits.credit_payload(guest_id, as_of(params))})
  end

  # Expiry is reported as of the optional `on` date, or the current UTC date.
  defp as_of(params) do
    with value when is_binary(value) <- Map.get(params, "on"),
         {:ok, date} <- Date.from_iso8601(value) do
      date
    else
      _other -> Date.utc_today()
    end
  end
end
