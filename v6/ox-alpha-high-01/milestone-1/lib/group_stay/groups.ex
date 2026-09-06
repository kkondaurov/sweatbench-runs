defmodule GroupStay.Groups do
  @moduledoc """
  Applies partner operations to group reservations and reads their deposit state.

  Operations are applied one at a time, each in its own database transaction, so a
  rejected operation leaves the data exactly as it was and never affects later
  operations in a batch.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query, only: [from: 2]

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @refund_notice_days 14
  @flexible_deposit_percent 20

  # -- Applying operations ---------------------------------------------------

  @doc """
  Applies each operation in array order and returns one result map per operation.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single partner operation and returns its result map.
  """
  def apply_operation(operation) when is_map(operation) do
    operation
    |> parse()
    |> execute()
    |> unwrap_error()
  rescue
    _ -> reject(Map.get(operation, "operation_id"), "invalid_operation")
  end

  def apply_operation(_operation), do: reject(nil, "invalid_operation")

  # -- Reading ----------------------------------------------------------------

  @doc """
  Fetches a group by its partner identifier.
  """
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  @doc """
  Renders a group for the API.
  """
  def group_json(%Group{} = group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  @doc """
  Cash totals across all groups. Only cash that was actually paid appears here.
  """
  def ledger_json do
    {held, refunded, retained} =
      from(g in Group,
        select: {g.status, g.deposit_paid_cents, g.refunded_cents, g.retained_cents}
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0}, fn
        {"active", paid, refunded, retained}, {held, r, t} ->
          {held + paid, r + refunded, t + retained}

        {_cancelled, _paid, refunded, retained}, {held, r, t} ->
          {held, r + refunded, t + retained}
      end)

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained
    }
  end

  # -- Parsing ------------------------------------------------------------------
  #
  # Parsing rejects only operations missing data needed to identify or route them
  # (`invalid_operation`). Domain rules are evaluated later so that group existence
  # and revision checks take precedence as documented.

  defp parse(%{"type" => "open_group"} = operation) do
    with :ok <-
           require_fields(
             operation,
             ~w(occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         {:ok, identifiers} <- identifiers(operation),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :open_group, operation["operation_id"],
       Map.merge(identifiers, %{occurred_on: occurred_on, raw: operation})}
    end
  end

  defp parse(%{"type" => "record_cash_payment"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id amount_cents)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :record_cash_payment, operation["operation_id"],
       %{group_id: group_id, occurred_on: occurred_on, raw: operation}}
    end
  end

  defp parse(%{"type" => "reschedule_group"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id new_arrival_on)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :reschedule_group, operation["operation_id"],
       %{group_id: group_id, occurred_on: occurred_on, raw: operation}}
    end
  end

  defp parse(%{"type" => "cancel_group"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :cancel_group, operation["operation_id"],
       %{group_id: group_id, occurred_on: occurred_on, raw: operation}}
    end
  end

  defp parse(operation),
    do: {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}

  # -- Execution --------------------------------------------------------------

  defp execute({:apply, :open_group, operation_id, cmd}) do
    raw = cmd.raw

    with {:ok, arrival_on} <- stay_date(operation_id, cmd.group_id, raw["arrival_on"]),
         {:ok, departure_on} <- stay_date(operation_id, cmd.group_id, raw["departure_on"]),
         :ok <- stay_order(operation_id, cmd.group_id, arrival_on, departure_on),
         {:ok, rooms} <- rooms(operation_id, cmd.group_id, raw["rooms"]),
         :ok <- rate_plan(operation_id, cmd.group_id, raw["rate_plan"]) do
      transact(fn ->
        if Repo.exists?(from g in Group, where: g.group_id == ^cmd.group_id) do
          Repo.rollback(reject(operation_id, "group_already_exists", cmd.group_id))
        else
          group =
            new_group(%{
              group_id: cmd.group_id,
              guest_id: cmd.guest_id,
              property_id: cmd.property_id,
              occurred_on: cmd.occurred_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: raw["rate_plan"],
              rooms: rooms
            })

          Repo.insert!(group)

          applied(operation_id, %{
            "group_id" => group.group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })
        end
      end)
    end
  end

  defp execute({:apply, kind, operation_id, cmd})
       when kind in [:record_cash_payment, :reschedule_group, :cancel_group] do
    raw = cmd.raw

    transact(fn ->
      group = Repo.get_by(Group, group_id: cmd.group_id)

      cond do
        is_nil(group) ->
          Repo.rollback(reject(operation_id, "group_not_found", cmd.group_id))

        stale_revision?(group, raw["expected_revision"]) ->
          Repo.rollback(
            reject(operation_id, "stale_revision", cmd.group_id,
              expected_revision: raw["expected_revision"],
              actual_revision: group.revision
            )
          )

        group.status != "active" ->
          Repo.rollback(reject(operation_id, "group_not_active", cmd.group_id))

        true ->
          apply_group_operation(kind, operation_id, cmd, group)
      end
    end)
  end

  defp execute({:error, rejection}), do: rejection

  defp apply_group_operation(:record_cash_payment, operation_id, cmd, group) do
    amount_cents = cmd.raw["amount_cents"]

    if usable_amount?(amount_cents) do
      outstanding_before = group.deposit_due_cents - group.deposit_paid_cents

      if amount_cents > outstanding_before do
        Repo.rollback(reject(operation_id, "payment_exceeds_outstanding", group.group_id))
      else
        revision = group.revision + 1

        group
        |> change(deposit_paid_cents: group.deposit_paid_cents + amount_cents, revision: revision)
        |> Repo.update!()

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_before - amount_cents,
          "revision" => revision
        })
      end
    else
      Repo.rollback(reject(operation_id, "invalid_amount", group.group_id))
    end
  end

  defp apply_group_operation(:reschedule_group, operation_id, cmd, group) do
    with {:ok, new_arrival_on} <-
           stay_date(operation_id, group.group_id, cmd.raw["new_arrival_on"]),
         :ok <- move_after(operation_id, group.group_id, new_arrival_on, cmd.occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)
      revision = group.revision + 1

      group
      |> change(arrival_on: new_arrival_on, departure_on: new_departure_on, revision: revision)
      |> Repo.update!()

      applied(operation_id, %{
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "revision" => revision
      })
    end
  end

  defp apply_group_operation(:cancel_group, operation_id, cmd, group) do
    refundable? =
      group.rate_plan == "flexible" and
        Date.diff(group.arrival_on, cmd.occurred_on) >= @refund_notice_days

    paid_cents = group.deposit_paid_cents
    {refunded_cents, retained_cents} = if refundable?, do: {paid_cents, 0}, else: {0, paid_cents}
    revision = group.revision + 1

    group
    |> change(
      status: "cancelled",
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: revision
    )
    |> Repo.update!()

    applied(operation_id, %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "revision" => revision
    })
  end

  # -- Group construction -------------------------------------------------------

  defp new_group(fields) do
    nights = Date.diff(fields.departure_on, fields.arrival_on)

    lodging_total_cents =
      fields.rooms
      |> Enum.map(&(&1.nightly_rate_cents * nights))
      |> Enum.sum()

    deposit_due_cents =
      fields.rooms
      |> Enum.map(&room_deposit(&1.nightly_rate_cents * nights, fields.rate_plan))
      |> Enum.sum()

    %Group{
      group_id: fields.group_id,
      guest_id: fields.guest_id,
      property_id: fields.property_id,
      rate_plan: fields.rate_plan,
      status: "active",
      revision: 1,
      booked_on: fields.occurred_on,
      arrival_on: fields.arrival_on,
      departure_on: fields.departure_on,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      rooms: fields.rooms
    }
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp room_deposit(lodging_cents, "flexible"),
    do: percent_half_up(lodging_cents, @flexible_deposit_percent)

  # Rounds amount * percent / 100 to the nearest cent; an exact half-cent rounds up.
  defp percent_half_up(amount_cents, percent) do
    div(amount_cents * percent * 2 + 100, 200)
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  # -- Validation helpers ---------------------------------------------------------

  defp stale_revision?(_group, nil), do: false
  defp stale_revision?(group, expected_revision), do: expected_revision != group.revision

  defp require_fields(operation, fields) do
    if Enum.any?(fields, &is_nil(Map.get(operation, &1))) do
      {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    else
      :ok
    end
  end

  defp identifiers(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, guest_id} <- identifier(operation, "guest_id"),
         {:ok, property_id} <- identifier(operation, "property_id") do
      {:ok, %{group_id: group_id, guest_id: guest_id, property_id: property_id}}
    end
  end

  defp identifier(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    end
  end

  defp operation_date(operation) do
    case date_value(Map.get(operation, "occurred_on")) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    end
  end

  defp stay_date(operation_id, group_id, value) do
    case date_value(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, reject(operation_id, "invalid_stay", group_id)}
    end
  end

  defp date_value(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp date_value(_value), do: :error

  defp stay_order(operation_id, group_id, arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, reject(operation_id, "invalid_stay", group_id)}
    end
  end

  defp move_after(operation_id, group_id, new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, reject(operation_id, "invalid_stay", group_id)}
    end
  end

  defp rooms(operation_id, group_id, rooms) when is_list(rooms) do
    parsed_rooms = Enum.map(rooms, &parse_room/1)
    room_ids = Enum.map(parsed_rooms, fn room -> room && room.room_id end)

    unique_room_ids? = length(Enum.uniq(room_ids)) == length(room_ids)

    if parsed_rooms != [] and not Enum.any?(parsed_rooms, &is_nil/1) and unique_room_ids? do
      {:ok, parsed_rooms}
    else
      {:error, reject(operation_id, "invalid_rooms", group_id)}
    end
  end

  defp rooms(operation_id, group_id, _other),
    do: {:error, reject(operation_id, "invalid_rooms", group_id)}

  defp parse_room(room) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate_cents = room["nightly_rate_cents"]

    if is_binary(room_id) and room_id != "" and usable_amount?(nightly_rate_cents) do
      %Room{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
    end
  end

  defp parse_room(_room), do: nil

  defp rate_plan(_operation_id, _group_id, rate_plan) when rate_plan in @rate_plans, do: :ok

  defp rate_plan(operation_id, group_id, _other),
    do: {:error, reject(operation_id, "invalid_rate_plan", group_id)}

  defp usable_amount?(amount_cents),
    do: is_integer(amount_cents) and not is_boolean(amount_cents) and amount_cents > 0

  # -- Result helpers ---------------------------------------------------------------

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, outcome} -> outcome
      {:error, rejection} -> rejection
    end
  end

  defp unwrap_error({:error, rejection}) when is_map(rejection), do: rejection
  defp unwrap_error(result), do: result

  defp applied(operation_id, fields) do
    Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)
  end

  defp reject(operation_id, code, group_id \\ nil, extra \\ []) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    |> maybe_put_group_id(group_id)
    |> Map.merge(Map.new(extra))
  end

  defp maybe_put_group_id(result, nil), do: result
  defp maybe_put_group_id(result, group_id), do: Map.put(result, "group_id", group_id)
end
