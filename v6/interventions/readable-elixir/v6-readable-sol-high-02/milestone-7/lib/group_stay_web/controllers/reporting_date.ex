defmodule GroupStayWeb.ReportingDate do
  @moduledoc false

  def parse(params) do
    case Map.fetch(params, "on") do
      :error -> {:ok, Date.utc_today()}
      {:ok, on} when is_binary(on) -> Date.from_iso8601(on)
      {:ok, _on} -> {:error, :invalid_date}
    end
  end
end
