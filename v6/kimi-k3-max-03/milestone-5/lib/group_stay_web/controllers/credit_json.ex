defmodule GroupStayWeb.CreditJSON do
  @moduledoc false

  def render("show.json", %{guest_id: guest_id, credit: credit}) do
    %{
      data: %{
        guest_id: guest_id,
        available_cents: credit.available_cents,
        lots: Enum.map(credit.lots, &serialize_lot/1)
      }
    }
  end

  defp serialize_lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    }
  end
end
