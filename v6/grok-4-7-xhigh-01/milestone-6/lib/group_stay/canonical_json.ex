defmodule GroupStay.CanonicalJson do
  @moduledoc false

  def encode(value) do
    IO.iodata_to_binary(encode_value(value))
  end

  defp encode_value(%_{} = struct) do
    raise ArgumentError, "cannot canonicalize #{inspect(struct.__struct__)}"
  end

  defp encode_value(map) when is_map(map) do
    entries =
      Enum.map(map, fn {key, value} ->
        [Jason.encode!(key_string(key)), ":", encode_value(value)]
      end)

    ["{", Enum.intersperse(Enum.sort(entries), ","), "}"]
  end

  defp encode_value(list) when is_list(list) do
    ["[", Enum.intersperse(Enum.map(list, &encode_value/1), ","), "]"]
  end

  defp encode_value(value), do: Jason.encode!(value)

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
end
