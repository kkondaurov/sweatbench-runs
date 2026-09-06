defmodule GroupStayWeb.QueryDate do
  @moduledoc """
  Parses the optional `on=YYYY-MM-DD` query parameter used by the credit and
  ledger reads to report expiry as of a date. Without it, reads use the
  current UTC date.
  """

  @spec parse(term()) :: {:ok, Date.t()} | :error
  def parse(nil), do: {:ok, Date.utc_today()}

  def parse(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  def parse(_value), do: :error
end
