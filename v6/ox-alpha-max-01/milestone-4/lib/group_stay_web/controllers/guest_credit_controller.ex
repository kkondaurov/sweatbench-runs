defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit
  alias GroupStayWeb.Params

  @moduledoc """
  Renders a guest's available hotel credit: unexpired, unexhausted lots
  ordered by earliest expiry, then source operation.
  """

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, as_of} <- Params.parse_on(params) do
      lots = Credit.available_lots(guest_id, as_of)

      json(conn, %{
        "data" => %{
          "guest_id" => guest_id,
          "available_cents" => Credit.available_cents(lots),
          "lots" =>
            Enum.map(lots, fn lot ->
              %{
                "source_operation_id" => lot.source_operation_id,
                "remaining_cents" => lot.remaining_cents,
                "expires_on" => Date.to_iso8601(lot.expires_on)
              }
            end)
        }
      })
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
