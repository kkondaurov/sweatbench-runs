defmodule GroupStay.PartnerOperations do
  @moduledoc false

  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Repo

  def get(operation_id) when is_binary(operation_id),
    do: Repo.get_by(Operation, operation_id: operation_id)

  def get(_operation_id), do: nil

  def record(attrs) do
    %Operation{}
    |> Ecto.Changeset.cast(attrs, [
      :operation_id,
      :operation_type,
      :payload,
      :canonical_payload,
      :result
    ])
    |> Ecto.Changeset.validate_required([:operation_id, :payload, :canonical_payload, :result])
    |> Ecto.Changeset.unique_constraint(:operation_id)
    |> Repo.insert()
  end
end
