defmodule GroupStay.PartnerBatches do
  @moduledoc """
  Processes partner operations in order, preserving one outcome per input value.
  Each operation commits independently; unexpected exceptions abort the batch,
  leaving earlier results available for a durable retry.
  """

  alias GroupStay.Operations

  def submit(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &Operations.process/1)}
  end

  def submit(_batch), do: {:error, :invalid_batch}
end
