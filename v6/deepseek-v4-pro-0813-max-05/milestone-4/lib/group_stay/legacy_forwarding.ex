defmodule GroupStay.LegacyForwarding do
  use Ecto.Schema

  alias GroupStay.Group

  @moduledoc """
  Marks a group whose pre-durable funding has been brought forward into
  room allocations. The row is committed in the same transaction as the
  allocation rows it covers.
  """

  @primary_key false

  schema "legacy_forwardings" do
    belongs_to :group, Group, primary_key: true, type: :binary_id

    timestamps()
  end
end
