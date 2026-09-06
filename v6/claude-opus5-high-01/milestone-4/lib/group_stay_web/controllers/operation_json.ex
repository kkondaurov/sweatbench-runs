defmodule GroupStayWeb.OperationJSON do
  @moduledoc """
  Renders the result GroupStay returned for a remembered operation.

  Only the stored result is exposed; the retained submission and the order the
  records were committed in stay internal to Northstar's audit trail.
  """

  alias GroupStay.Operations.Record

  def show(%{record: %Record{} = record}), do: %{data: record.result}
end
