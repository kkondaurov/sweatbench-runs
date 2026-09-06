defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay

  def show(conn, %{"guest_id" => guest_id} = params) do
    as_of = parsed_on(params["on"]) || Date.utc_today()
    credit = GroupStay.guest_credit(guest_id, as_of)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{data: credit_view(credit, guest_id)}))
  end

  defp credit_view(%{available_cents: available_cents, lots: lots}, guest_id) do
    %{
      "guest_id" => guest_id,
      "available_cents" => available_cents,
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  defp parsed_on(nil), do: nil

  defp parsed_on(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parsed_on(_other), do: nil
end
