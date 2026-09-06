defmodule GroupStay.Operations.RescheduleGroup do
  @moduledoc """
  Moves an active group's stay from a `reschedule_group` operation. The
  departure shifts by the same number of calendar days as the arrival, so the
  length and price of the stay are unchanged. The new arrival must fall after
  the operation date.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Operations
  alias GroupStay.Repo

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on, :new_arrival_on]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         true <- is_binary(fields.group_id),
         {:ok, occurred_on} <- Operations.parse_date(fields.occurred_on) do
      process(operation, fields, occurred_on)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp process(operation, fields, occurred_on) do
    case Repo.transaction(fn ->
           group = Repo.get_by(Group, group_id: fields.group_id)
           apply_to_group(operation, group, fields.new_arrival_on, occurred_on)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_to_group(operation, group, new_arrival_on, occurred_on) do
    with :ok <- Operations.guard_group(operation, group),
         {:ok, date} <- validate_new_arrival(new_arrival_on, occurred_on) do
      apply_reschedule(operation, group, date)
    else
      {:rejected, result} -> result
      :invalid_stay -> Operations.rejected(operation, "invalid_stay")
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    case Operations.parse_date(new_arrival_on) do
      {:ok, date} ->
        if Date.compare(date, occurred_on) == :gt do
          {:ok, date}
        else
          :invalid_stay
        end

      :error ->
        :invalid_stay
    end
  end

  defp apply_reschedule(operation, group, new_arrival) do
    shift = Date.diff(new_arrival, group.arrival_on)
    new_departure = Date.add(group.departure_on, shift)
    revision = group.revision + 1

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [arrival_on: new_arrival, departure_on: new_departure, revision: revision]
      )

    Operations.applied(operation,
      group_id: group.group_id,
      new_arrival_on: Date.to_iso8601(new_arrival),
      new_departure_on: Date.to_iso8601(new_departure),
      revision: revision
    )
  end
end
