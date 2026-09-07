defmodule GroupStayWeb.ReportingDate do
  @moduledoc false

  def from_params(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def from_params(%{"on" => _value}), do: :error
  def from_params(_params), do: {:ok, Date.utc_today()}
end
