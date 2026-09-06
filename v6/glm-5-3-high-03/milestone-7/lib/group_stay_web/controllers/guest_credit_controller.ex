defmodule GroupStayWeb.GuestCreditController do
  @moduledoc """
  Reads a guest's hotel credit: the lots that still hold value and are
  unexpired, as of the optional `on` query parameter or the current UTC date.
  """

  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{"data" => GroupStay.Credits.guest_credit_data(guest_id, as_of(params))})
  end

  defp as_of(params) do
    case params["on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _} -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end
end
