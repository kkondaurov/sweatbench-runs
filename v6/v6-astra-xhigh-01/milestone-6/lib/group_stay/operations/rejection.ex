defmodule GroupStay.Operations.Rejection do
  @moduledoc """
  A handled domain rejection. Only this exception is converted into a durable
  rejected result; unexpected faults must roll back and propagate to the endpoint.
  """

  defexception [:details, message: "partner operation rejected"]

  def reject(code, details \\ %{}) do
    raise __MODULE__, details: Map.put(details, :code, code)
  end
end
