defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStayWeb.AsOfDate.parse(params) do
      {:ok, as_of} ->
        lots = GroupStay.Credits.available_lots(guest_id, as_of)

        json(conn, %{
          data: %{
            guest_id: guest_id,
            available_cents: lots |> Enum.map(& &1.remaining_cents) |> Enum.sum(),
            lots: Enum.map(lots, &lot/1)
          }
        })

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end
end
