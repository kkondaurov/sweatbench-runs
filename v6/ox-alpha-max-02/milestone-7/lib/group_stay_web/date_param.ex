defmodule GroupStayWeb.DateParam do
  @moduledoc """
  Parses ISO 8601 date query parameters used by read endpoints. The optional
  `on` parameter of the credit and ledger reads falls back to the current UTC
  date when absent; the finance report's `date` parameter is required.
  """

  def reference_date(nil), do: {:ok, Date.utc_today()}

  def reference_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def reference_date(_value), do: :error

  def reporting_date(value) when is_binary(value) do
    case reference_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, :invalid_reporting_date}
    end
  end

  def reporting_date(_value), do: {:error, :invalid_reporting_date}
end
