defmodule GroupStayWeb.GuestCreditJSON do
  @moduledoc """
  Renders a guest's available hotel credit lots.
  """

  def show(%{credit: credit}) do
    %{
      data: %{
        guest_id: credit.guest_id,
        available_cents: credit.available_cents,
        lots: Enum.map(credit.lots, &lot/1)
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
