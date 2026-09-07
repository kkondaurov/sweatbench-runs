defmodule GroupStay.PartnerOperations.OperationRecord do
  @moduledoc """
  The durable audit and idempotency record for a partner operation.

  `submission` retains the complete JSON object received from the gateway and
  `result` is the exact response originally produced for it. The generated
  primary key records first-commit order; callers should not attach business
  meaning to it beyond that ordering.

  A record is initially inserted without a result to claim its operation ID.
  It is completed in the same transaction, so an incomplete record can never
  be observed after a commit.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:commit_order, :id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "partner_operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def claim_changeset(record, submission) do
    record
    |> cast(
      %{
        operation_id: submission["operation_id"],
        operation_type: submitted_type(submission),
        submission: submission
      },
      [:operation_id, :operation_type, :submission]
    )
    |> validate_required([:operation_id, :submission])
    |> unique_constraint(:operation_id)
  end

  def result_changeset(record, result) do
    record
    |> change(result: result)
    |> validate_required(:result)
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_submission), do: nil
end
