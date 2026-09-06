defmodule GroupStay do
  @moduledoc """
  Applies partner operations and reads reservation and cash accounting records.
  """

  import Ecto.Query
  alias GroupStay.{Group, Repo, Room}

  @operation_fields %{
    "open_group" => ~w(occurred_on guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(occurred_on amount_cents),
    "reschedule_group" => ~w(occurred_on new_arrival_on),
    "cancel_group" => ~w(occurred_on)
  }
  @max_cents 9_223_372_036_854_775_807

  @doc "Applies operations in order, committing each successful operation independently."
  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc "Returns the public group representation, or nil when it does not exist."
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> group_data()
    end
  end

  @doc "Returns cash currently held and cumulative cancellation settlements."
  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents: coalesce(sum(g.deposit_paid_cents), 0),
          cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0)
        }
    )
  end

  defp submit_operation(operation) do
    # SQLite must acquire its write lock before reading the revision. A deferred
    # transaction can read an obsolete snapshot before attempting to write.
    case Repo.transaction(fn -> apply_operation(operation) end, mode: :immediate) do
      {:ok, result} ->
        Map.merge(result, %{operation_id: operation["operation_id"], status: "applied"})

      {:error, details} ->
        operation_id = if is_map(operation), do: operation["operation_id"]
        Map.merge(details, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    unless valid_identifier?(operation["operation_id"]) and
             valid_identifier?(operation["group_id"]) and
             is_map_key(@operation_fields, operation["type"]) do
      reject("invalid_operation")
    end

    case operation["type"] do
      "open_group" ->
        require_fields(operation)
        open_group(operation)

      type ->
        group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
        check_revision(group, operation)
        require_fields(operation)
        unless group.status == "active", do: reject("group_not_active")
        update_group(type, group, operation)
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp require_fields(operation) do
    unless Enum.all?(@operation_fields[operation["type"]], &Map.has_key?(operation, &1)) do
      reject("invalid_operation")
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      reject("stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp open_group(operation) do
    unless valid_identifier?(operation["guest_id"]) and
             valid_identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    booked_on = date!(operation["occurred_on"], "invalid_stay")
    arrival_on = date!(operation["arrival_on"], "invalid_stay")
    departure_on = date!(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    unless nights > 0, do: reject("invalid_stay")

    rate_plan = operation["rate_plan"]
    unless rate_plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")
    rooms = validate_rooms(operation["rooms"])

    {lodging_total, deposit_due} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging, deposit} ->
        amount = nights * room["nightly_rate_cents"]
        due = if rate_plan == "flexible", do: round_percentage(amount, 20), else: amount
        {lodging + amount, deposit + due}
      end)

    unless lodging_total <= @max_cents, do: reject("invalid_rooms")

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      })

    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        group_id: group.group_id,
        room_id: room["room_id"],
        position: position,
        nightly_rate_cents: room["nightly_rate_cents"]
      })
    end)

    %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: group.revision}
  end

  defp update_group("record_cash_payment", group, operation) do
    date!(operation["occurred_on"], "invalid_operation")
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    group = persist_update(group, deposit_paid_cents: group.deposit_paid_cents + amount)

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp update_group("reschedule_group", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_stay")
    arrival_on = date!(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival_on, occurred_on) == :gt, do: reject("invalid_stay")
    departure_on = shift_departure(arrival_on, Date.diff(group.departure_on, group.arrival_on))
    group = persist_update(group, arrival_on: arrival_on, departure_on: departure_on)

    %{
      group_id: group.group_id,
      new_arrival_on: group.arrival_on,
      new_departure_on: group.departure_on,
      revision: group.revision
    }
  end

  defp update_group("cancel_group", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_operation")
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.deposit_paid_cents

    group =
      persist_update(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained
      )

    %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: group.revision
    }
  end

  defp persist_update(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0 and
          room["nightly_rate_cents"] <= @max_cents
      end)

    unless valid, do: reject("invalid_rooms")
    identifiers = Enum.map(rooms, & &1["room_id"])
    unless length(Enum.uniq(identifiers)) == length(rooms), do: reject("invalid_rooms")
    rooms
  end

  defp validate_rooms(_rooms), do: reject("invalid_rooms")

  # Integer arithmetic preserves cent precision, including half-cent rounding.
  defp round_percentage(amount, percent), do: div(amount * percent + 50, 100)
  defp valid_identifier?(value), do: is_binary(value) and value != ""
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp date!(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> reject(code)
    end
  end

  defp date!(_value, code), do: reject(code)

  defp shift_departure(arrival_on, nights) do
    departure_on = Date.add(arrival_on, nights)
    # Date.add/2 can produce years outside the API's ISO 8601 date format.
    unless departure_on.year in -9999..9999, do: reject("invalid_stay")
    departure_on
  end

  defp reject(code, details \\ %{}), do: Repo.rollback(Map.put(details, :code, code))

  defp group_data(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents
    ])
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
    |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
  end
end
