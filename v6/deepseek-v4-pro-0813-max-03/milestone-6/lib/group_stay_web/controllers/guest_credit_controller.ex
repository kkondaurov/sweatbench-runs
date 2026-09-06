defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Credit.guest_credit_json(guest_id, as_of(params))})
  end

  defp as_of(params) do
    case params["on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end
end
