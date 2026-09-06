defmodule GroupStay.CanonicalJSON do
  @moduledoc """
  Canonical JSON encoding used to compare submitted operation payloads.
  Object key order is insignificant; array order and values are significant.
  """

  @doc """
  Encodes decoded-JSON data (maps, lists, strings, numbers, booleans, nil)
  into a deterministic string with object keys sorted.
  """
  def encode(term) when is_map(term) do
    pairs =
      term
      |> Enum.map(fn {key, value} -> Jason.encode!(to_string(key)) <> ":" <> encode(value) end)
      |> Enum.sort()
      |> Enum.join(",")

    "{" <> pairs <> "}"
  end

  def encode(term) when is_list(term) do
    "[" <> Enum.map_join(term, ",", &encode/1) <> "]"
  end

  def encode(term) when is_binary(term), do: Jason.encode!(term)
  def encode(term) when is_integer(term), do: Integer.to_string(term)
  def encode(term) when is_float(term), do: Jason.encode!(term)
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(nil), do: "null"
end
