defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations and exposes the resulting group and ledger views.

  Every operation has its own database transaction. This lets a batch retain earlier
  successes while guaranteeing that a rejected operation cannot leave partial data behind.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @rate_plans ~w(flexible advance_purchase)

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def group_view(%Group{} = group) do
    group = if Ecto.assoc_loaded?(group.rooms), do: group, else: Repo.preload(group, :rooms)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  def ledger_view do
    totals =
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

    Map.new(totals, fn {key, value} -> {key, value || 0} end)
  end

  defp process(operation) when not is_map(operation), do: rejected(nil, "invalid_operation")

  defp process(operation) do
    operation_id = operation["operation_id"]

    with :ok <- valid_common(operation),
         type when type in @operation_types <- operation["type"] do
      apply_operation(type, operation)
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp valid_common(%{
         "operation_id" => operation_id,
         "type" => type,
         "occurred_on" => occurred_on
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on),
       do: :ok

  defp valid_common(_operation), do: :error

  defp apply_operation("open_group", operation), do: open_group(operation)

  defp apply_operation(type, operation) do
    operation_id = operation["operation_id"]

    if valid_identifier?(operation["group_id"]) do
      Repo.transaction(
        fn ->
          case Repo.get(Group, operation["group_id"]) do
            nil -> rejected(operation_id, "group_not_found")
            group -> apply_to_existing(type, operation, group)
          end
        end,
        mode: :immediate
      )
      |> transaction_result()
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp open_group(operation) do
    operation_id = operation["operation_id"]

    with :ok <- require_open_fields(operation),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_stay_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_stay_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = rooms |> Enum.map(&(&1["nightly_rate_cents"] * nights)) |> Enum.sum()

      deposit_due =
        rooms
        |> Enum.map(fn room ->
          lodging = room["nightly_rate_cents"] * nights
          room_deposit(lodging, operation["rate_plan"])
        end)
        |> Enum.sum()

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        revision: 1
      }

      multi =
        Multi.new()
        |> Multi.insert(
          :group,
          %Group{}
          |> Ecto.Changeset.change(attrs)
          |> Ecto.Changeset.unique_constraint(:group_id)
        )
        |> Multi.run(:rooms, fn repo, %{group: group} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          rows =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                group_id: group.group_id,
                position: position,
                room_id: room["room_id"],
                nightly_rate_cents: room["nightly_rate_cents"],
                inserted_at: now,
                updated_at: now
              }
            end)

          {_count, inserted} = repo.insert_all(Room, rows, returning: true)
          {:ok, inserted}
        end)

      case Repo.transaction(multi, mode: :immediate) do
        {:ok, _changes} ->
          applied(operation_id, %{
            group_id: operation["group_id"],
            deposit_due_cents: deposit_due,
            revision: 1
          })

        {:error, :group, changeset, _changes} ->
          if unique_error?(changeset) do
            rejected(operation_id, "group_already_exists")
          else
            rejected(operation_id, "invalid_operation")
          end

        {:error, _step, _reason, _changes} ->
          rejected(operation_id, "invalid_operation")
      end
    else
      {:error, code} -> rejected(operation_id, code)
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_to_existing(type, operation, group) do
    operation_id = operation["operation_id"]

    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      rejected(operation_id, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      case parse_date(operation["occurred_on"]) do
        {:ok, _occurred_on} -> apply_existing_domain(type, operation, group)
        :error -> rejected(operation_id, "invalid_operation")
      end
    end
  end

  defp apply_existing_domain("record_cash_payment", operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rejected(operation["operation_id"], "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rejected(operation["operation_id"], "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]
        updated = update_group!(group, deposit_paid_cents: group.deposit_paid_cents + amount)

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(updated),
          revision: updated.revision
        })
    end
  end

  defp apply_existing_domain("reschedule_group", operation, group) do
    cond do
      not Map.has_key?(operation, "new_arrival_on") ->
        rejected(operation["operation_id"], "invalid_operation")

      group.status != "active" ->
        rejected(operation["operation_id"], "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, shift)

          updated =
            update_group!(group,
              arrival_on: new_arrival_on,
              departure_on: new_departure_on
            )

          applied(operation["operation_id"], %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            revision: updated.revision
          })
        else
          _ -> rejected(operation["operation_id"], "invalid_stay")
        end
    end
  end

  defp apply_existing_domain("cancel_group", operation, group) do
    if group.status != "active" do
      rejected(operation["operation_id"], "group_not_active")
    else
      case parse_date(operation["occurred_on"]) do
        {:ok, occurred_on} ->
          refundable =
            group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

          refunded = if refundable, do: group.deposit_paid_cents, else: 0
          retained = if refundable, do: 0, else: group.deposit_paid_cents

          updated =
            update_group!(group,
              status: "cancelled",
              cash_refunded_cents: refunded,
              cash_retained_cents: retained
            )

          applied(operation["operation_id"], %{
            group_id: group.group_id,
            refunded_cents: refunded,
            retained_cents: retained,
            revision: updated.revision
          })

        :error ->
          rejected(operation["operation_id"], "invalid_operation")
      end
    end
  end

  defp update_group!(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(%Group{status: "cancelled"}), do: 0

  defp outstanding(%Group{} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp require_open_fields(operation) do
    identifiers_valid? =
      Enum.all?(~w(group_id guest_id property_id), fn key -> valid_identifier?(operation[key]) end)

    fields_present? =
      Enum.all?(~w(arrival_on departure_on rate_plan rooms), &Map.has_key?(operation, &1))

    if identifiers_valid? and fields_present?, do: :ok, else: :error
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _ ->
          false
      end)

    ids = Enum.map(rooms, & &1["room_id"])

    if valid? and Enum.uniq(ids) == ids,
      do: {:ok, rooms},
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp room_deposit(lodging, "advance_purchase"), do: lodging
  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp valid_identifier?(identifier), do: is_binary(identifier) and identifier != ""

  defp unique_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique
    end)
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, _reason}), do: raise("operation transaction failed")

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
end
