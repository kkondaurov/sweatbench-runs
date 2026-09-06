defmodule GroupStayWeb.GuestCreditJSON do
  def show(%{credit: credit}) do
    %{
      data: %{
        guest_id: credit.guest_id,
        available_cents: credit.available_cents,
        lots: Enum.map(credit.lots, &lot/1)
      }
    }
  end

  def error(%{code: code}), do: %{error: %{code: code}}

  defp lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    }
  end
end
