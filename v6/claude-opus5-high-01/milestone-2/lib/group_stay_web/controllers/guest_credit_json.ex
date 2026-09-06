defmodule GroupStayWeb.GuestCreditJSON do
  @moduledoc "Renders the hotel credit a guest can still spend."

  def show(%{guest_id: guest_id, lots: lots}) do
    %{
      data: %{
        guest_id: guest_id,
        available_cents: lots |> Enum.map(& &1.remaining_cents) |> Enum.sum(),
        lots: Enum.map(lots, &lot/1)
      }
    }
  end

  defp lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end
end
