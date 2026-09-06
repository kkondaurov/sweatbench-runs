defmodule GroupStayWeb.AsOf do
  @moduledoc """
  The date a read reports expiry as of.

  Reads accept an optional `on=YYYY-MM-DD` query parameter and otherwise use the current UTC date.
  """

  @doc """
  Returns `{:ok, date}` for the requested date, or `:error` when `on` is present but unusable.
  """
  def fetch(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  def fetch(%{"on" => _on}), do: :error

  def fetch(_params), do: {:ok, Date.utc_today()}
end
