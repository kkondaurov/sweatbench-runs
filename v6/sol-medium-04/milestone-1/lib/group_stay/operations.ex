defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{Group, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)
  @group_operation_fields %{
    "record_cash_payment" => ["operation_id", "type", "occurred_on", "group_id", "amount_cents"],
    "reschedule_group" => ["operation_id", "type", "occurred_on", "group_id", "new_arrival_on"],
    "cancel_group" => ["operation_id", "type", "occurred_on", "group_id"]
  }

  def process_batch(operations) do
    Enum.map(operations, &process/1)
  end

  def get_group(id) when is_binary(id) do
    case Repo.get(Group, id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_), do: nil

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0)
        }
    )
  end

  defp process(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      case Map.get(operation, "type") do
        "open_group" -> open_group(operation)
        type when is_map_key(@group_operation_fields, type) -> apply_to_group(type, operation)
        _ -> {:rejected, "invalid_operation", %{}}
      end

    format_result(operation_id, result)
  end

  defp process(_), do: format_result(nil, {:rejected, "invalid_operation", %{}})

  defp open_group(operation) do
    required =
      ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- require_fields(operation, required),
         :ok <-
           require_nonempty_strings(operation, ~w(operation_id group_id guest_id property_id)),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due =
        Enum.sum(
          Enum.map(rooms, fn room ->
            lodging = room.nightly_rate_cents * nights
            if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
          end)
        )

      attrs = %{
        id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        revision: 1
      }

      case Repo.transaction(fn -> insert_group(attrs, rooms) end, mode: :immediate) do
        {:ok, _group} ->
          {:applied, %{group_id: attrs.id, deposit_due_cents: deposit_due, revision: 1}}

        {:error, :already_exists} ->
          {:rejected, "group_already_exists", %{}}

        {:error, _reason} ->
          {:rejected, "invalid_operation", %{}}
      end
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp insert_group(attrs, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    group_row =
      Map.merge(attrs, %{
        deposit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        inserted_at: now,
        updated_at: now
      })

    case Repo.insert_all(Group, [group_row], on_conflict: :nothing, conflict_target: [:id]) do
      {1, nil} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            Map.merge(room, %{
              group_id: attrs.id,
              position: position,
              inserted_at: now,
              updated_at: now
            })
          end)

        {_count, nil} = Repo.insert_all(Room, room_rows)
        attrs.id

      {0, nil} ->
        Repo.rollback(:already_exists)
    end
  end

  defp apply_to_group(type, operation) do
    required = Map.fetch!(@group_operation_fields, type)

    with :ok <- require_fields(operation, required),
         :ok <- require_nonempty_strings(operation, ~w(operation_id group_id)) do
      case Repo.transaction(fn -> apply_locked(type, operation) end, mode: :immediate) do
        {:ok, result} -> result
        {:error, result} -> result
      end
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp apply_locked(type, operation) do
    group = Repo.one(from g in Group, where: g.id == ^operation["group_id"])

    cond do
      is_nil(group) ->
        Repo.rollback({:rejected, "group_not_found", %{}})

      stale_revision?(operation, group) ->
        Repo.rollback(
          {:rejected, "stale_revision",
           %{
             group_id: group.id,
             expected_revision: operation["expected_revision"],
             actual_revision: group.revision
           }}
        )

      invalid_expected_revision?(operation) ->
        Repo.rollback({:rejected, "invalid_operation", %{}})

      group.status != "active" ->
        Repo.rollback({:rejected, "group_not_active", %{}})

      true ->
        perform(type, operation, group)
    end
  end

  defp perform("record_cash_payment", operation, group) do
    amount = operation["amount_cents"]
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    cond do
      match?({:error, _}, parse_date(operation["occurred_on"], "invalid_operation")) ->
        Repo.rollback({:rejected, "invalid_operation", %{}})

      not is_integer(amount) or amount <= 0 ->
        Repo.rollback({:rejected, "invalid_amount", %{}})

      amount > outstanding ->
        Repo.rollback({:rejected, "payment_exceeds_outstanding", %{}})

      true ->
        revision = group.revision + 1

        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          revision: revision
        })

        {:applied,
         %{
           group_id: group.id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding - amount,
           revision: revision
         }}
    end
  end

  defp perform("reschedule_group", operation, group) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, new_arrival} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      shift = Date.diff(new_arrival, group.arrival_on)
      new_departure = Date.add(group.departure_on, shift)
      revision = group.revision + 1

      update_group!(group, %{
        arrival_on: new_arrival,
        departure_on: new_departure,
        revision: revision
      })

      {:applied,
       %{
         group_id: group.id,
         new_arrival_on: new_arrival,
         new_departure_on: new_departure,
         revision: revision
       }}
    else
      _ -> Repo.rollback({:rejected, "invalid_stay", %{}})
    end
  end

  defp perform("cancel_group", operation, group) do
    case parse_date(operation["occurred_on"], "invalid_operation") do
      {:ok, occurred_on} ->
        refundable =
          group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

        refunded = if refundable, do: group.deposit_paid_cents, else: 0
        retained = if refundable, do: 0, else: group.deposit_paid_cents
        revision = group.revision + 1

        update_group!(group, %{
          status: "cancelled",
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          revision: revision
        })

        {:applied,
         %{
           group_id: group.id,
           refunded_cents: refunded,
           retained_cents: retained,
           revision: revision
         }}

      {:error, _code} ->
        Repo.rollback({:rejected, "invalid_operation", %{}})
    end
  end

  defp update_group!(group, attrs) do
    group |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp stale_revision?(operation, group) do
    Map.has_key?(operation, "expected_revision") and
      operation["expected_revision"] != group.revision and
      is_integer(operation["expected_revision"])
  end

  defp invalid_expected_revision?(operation) do
    Map.has_key?(operation, "expected_revision") and
      not is_integer(operation["expected_revision"])
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          true

        _ ->
          false
      end)

    ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(ids) == ids do
      {:ok,
       Enum.map(rooms, &%{room_id: &1["room_id"], nightly_rate_cents: &1["nightly_rate_cents"]})}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp valid_stay(arrival, departure) do
    if Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp require_nonempty_strings(operation, fields) do
    if Enum.all?(fields, &(is_binary(operation[&1]) and operation[&1] != "")),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp format_result(operation_id, {:applied, fields}) do
    fields |> Map.put(:operation_id, operation_id) |> Map.put(:status, "applied")
  end

  defp format_result(operation_id, {:rejected, code, fields}) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "rejected")
    |> Map.put(:code, code)
  end
end
