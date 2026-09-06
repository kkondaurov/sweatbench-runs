defmodule GroupStay do
  @moduledoc """
  GroupStay keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias GroupStay.Operations

  defdelegate process_batch(params), to: Operations
  defdelegate get_group(group_id), to: Operations
  defdelegate ledger(), to: Operations
end
