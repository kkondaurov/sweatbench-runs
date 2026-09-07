defmodule GroupStayWeb.ReportingDate do
  @moduledoc false

  def parse(params) do
    case Map.fetch(params, "on") do
      :error -> {:ok, Date.utc_today()}
      {:ok, value} when is_binary(value) -> Date.from_iso8601(value)
      {:ok, _value} -> {:error, :invalid_format}
    end
  end
end
