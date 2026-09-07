defmodule GroupStay.Operations.Entry do
  @moduledoc """
  An immutable first submission and outcome. `id` orders durable commits;
  `operation_id` is the partner's unique retry key. `type` captures the submitted
  string type, including unknown types; malformed type values remain in submission.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
