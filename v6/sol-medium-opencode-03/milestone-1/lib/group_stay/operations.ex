defmodule GroupStay.Operations do
  import Ecto.Query

  alias Ecto.Multi
  alias GroupStay.{Group, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)

  def submit(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, rooms: from(r in Room, order_by: r.position))}
    end
  end

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
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0)
        }
    )
  end

  def serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(group.rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp process(operation) when is_map(operation) do
    operation_id = operation["operation_id"]

    result =
      with true <- valid_identifier?(operation_id),
           {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, result} <- dispatch(operation, occurred_on) do
        Map.merge(%{operation_id: operation_id, status: "applied"}, result)
      else
        false ->
          rejected(operation_id, "invalid_operation")

        :error ->
          rejected(operation_id, "invalid_operation")

        {:error, result} when is_map(result) ->
          result
          |> Map.put(:operation_id, operation_id)
          |> Map.put(:status, "rejected")

        {:error, code} ->
          rejected(operation_id, code)
      end

    result
  end

  defp process(_operation), do: rejected(nil, "invalid_operation")

  defp dispatch(%{"type" => "open_group"} = operation, occurred_on) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if required_fields?(operation, required),
      do: open_group(operation, occurred_on),
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "record_cash_payment"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id amount_cents))

  defp dispatch(%{"type" => "reschedule_group"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id new_arrival_on))

  defp dispatch(%{"type" => "cancel_group"} = operation, occurred_on),
    do: dispatch_update(operation, occurred_on, ~w(group_id))

  defp dispatch(_operation, _occurred_on), do: {:error, "invalid_operation"}

  defp open_group(operation, booked_on) do
    with {:ok, attrs} <- opening_attrs(operation, booked_on) do
      multi =
        Multi.new()
        |> Multi.insert(:group, Group.create_changeset(attrs))
        |> Multi.run(:rooms, fn repo, %{group: group} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          rooms =
            operation["rooms"]
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              %{
                group_record_id: group.id,
                room_id: room["room_id"],
                nightly_rate_cents: room["nightly_rate_cents"],
                position: position,
                inserted_at: now,
                updated_at: now
              }
            end)

          {count, _} = repo.insert_all(Room, rooms)
          if count == length(rooms), do: {:ok, rooms}, else: {:error, :invalid_rooms}
        end)

      case Repo.transaction(multi, mode: :immediate) do
        {:ok, %{group: group}} ->
          {:ok,
           %{
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}

        {:error, :group, changeset, _} ->
          if unique_error?(changeset, :group_id),
            do: {:error, "group_already_exists"},
            else: {:error, "invalid_operation"}

        {:error, _step, _reason, _changes} ->
          {:error, "invalid_operation"}
      end
    end
  end

  defp opening_attrs(operation, booked_on) do
    with true <- identifiers?(operation, ~w(group_id guest_id property_id)),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt || {:domain, "invalid_stay"},
         rate_plan when rate_plan in @rate_plans <-
           operation["rate_plan"] || {:domain, "invalid_rate_plan"},
         {:ok, room_totals} <-
           room_totals(operation["rooms"], Date.diff(departure_on, arrival_on), rate_plan) do
      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         status: "active",
         revision: 1,
         lodging_total_cents: room_totals.lodging,
         deposit_due_cents: room_totals.deposit
       }}
    else
      false -> {:error, "invalid_operation"}
      :error -> {:error, "invalid_stay"}
      {:domain, code} -> {:error, code}
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp room_totals(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0
      end)

    unique = Enum.uniq_by(rooms, & &1["room_id"]) |> length() == length(rooms)

    if valid and unique do
      totals =
        Enum.reduce(rooms, %{lodging: 0, deposit: 0}, fn room, totals ->
          lodging = nights * room["nightly_rate_cents"]
          deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
          %{lodging: totals.lodging + lodging, deposit: totals.deposit + deposit}
        end)

      {:ok, totals}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp room_totals(_rooms, _nights, _rate_plan), do: {:error, "invalid_rooms"}

  defp dispatch_update(operation, occurred_on, required) do
    if required_fields?(operation, required),
      do: update_group(operation, occurred_on),
      else: {:error, "invalid_operation"}
  end

  defp update_group(operation, occurred_on) do
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      Repo.transaction(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil -> Repo.rollback("group_not_found")
            group -> apply_to_group(group, operation, occurred_on)
          end
        end,
        mode: :immediate
      )
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, result} -> {:error, result}
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp apply_to_group(group, operation, occurred_on) do
    expected_revision = operation["expected_revision"]

    cond do
      not is_nil(expected_revision) and expected_revision != group.revision ->
        Repo.rollback(%{
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })

      group.status != "active" ->
        Repo.rollback("group_not_active")

      true ->
        apply_active(group, operation, occurred_on)
    end
  end

  defp apply_active(group, %{"type" => "record_cash_payment"} = operation, _occurred_on) do
    amount = operation["amount_cents"]
    outstanding = outstanding(group)

    cond do
      not is_integer(amount) or amount <= 0 ->
        Repo.rollback("invalid_amount")

      amount > outstanding ->
        Repo.rollback("payment_exceeds_outstanding")

      true ->
        group = update!(group, deposit_paid_cents: group.deposit_paid_cents + amount)

        %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp apply_active(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      new_departure = Date.add(new_arrival, Date.diff(group.departure_on, group.arrival_on))
      group = update!(group, arrival_on: new_arrival, departure_on: new_departure)

      %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival),
        new_departure_on: Date.to_iso8601(new_departure),
        revision: group.revision
      }
    else
      _ -> Repo.rollback("invalid_stay")
    end
  end

  defp apply_active(group, %{"type" => "cancel_group"}, occurred_on) do
    refundable =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.deposit_paid_cents

    group =
      update!(group,
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained
      )

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: group.revision
    }
  end

  defp update!(group, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
      |> Repo.update_all(set: Keyword.put(attrs, :updated_at, now), inc: [revision: 1])

    Repo.get!(Group, group.id)
  end

  defp outstanding(%Group{status: "active"} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding(_group), do: 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp identifiers?(operation, keys),
    do: Enum.all?(keys, &valid_identifier?(operation[&1]))

  defp required_fields?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> options[:constraint] == :unique
      _ -> false
    end)
  end

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}
end
