defmodule GroupStay.Operations.Payload do
  @moduledoc """
  Canonical JSON for the operations GroupStay remembers.

  Object keys are emitted in sorted order, so the key order a gateway happens to
  send is irrelevant, while array order and every value stay significant. Two
  submissions are equivalent exactly when their canonical text matches.
  """

  @doc "Canonical JSON text for a decoded JSON value."
  def canonical(value), do: value |> encode() |> IO.iodata_to_binary()

  defp encode(%_struct{} = value), do: Jason.encode_to_iodata!(value)

  defp encode(map) when is_map(map) do
    members =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_intersperse(?,, fn {key, value} ->
        [Jason.encode_to_iodata!(key), ?:, encode(value)]
      end)

    [?{, members, ?}]
  end

  defp encode(list) when is_list(list), do: [?[, Enum.map_intersperse(list, ?,, &encode/1), ?]]

  defp encode(value), do: Jason.encode_to_iodata!(value)
end
