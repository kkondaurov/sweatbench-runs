defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to group bookings and finance records.

  Each operation is applied inside its own database transaction. A rejected
  operation leaves the database exactly as it was before that operation began,
  and processing of the remaining batch continues.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Repo

  @flexible_deposit_percent 20
  @refundable_days_before_arrival 14
  @rate_plans ~w(flexible advance_purchase)

  @open_group_required ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

  @doc """
  Applies each operation in order and returns one result map per operation.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single operation and returns its result map.
  """
  def apply_operation(operation) when is_map(operation) do
    outcome =
      Repo.transaction(fn ->
        case dispatch(operation) do
          {:ok, fields} -> fields
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case outcome do
      {:ok, fields} -> success(operation, fields)
      {:error, reason} -> failure(operation, reason)
    end
  end

  def apply_operation(_operation), do: failure(%{}, :invalid_operation)

  # -- Operation handlers --------------------------------------------------

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)
  defp dispatch(_operation), do: {:error, :invalid_operation}

  defp open_group(operation) do
    with :ok <- require_fields(operation, @open_group_required),
         :ok <- reject_existing_group(operation["group_id"]),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], :invalid_stay),
         {:ok, departure_on} <- parse_date(operation["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      rate_plan = operation["rate_plan"]

      room_rows =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {{room_id, nightly_rate_cents}, position} ->
          lodging_amount_cents = nightly_rate_cents * nights

          %Room{
            position: position,
            room_id: room_id,
            nightly_rate_cents: nightly_rate_cents,
            lodging_amount_cents: lodging_amount_cents,
            deposit_cents: deposit_for(rate_plan, lodging_amount_cents)
          }
        end)

      lodging_total_cents = room_rows |> Enum.map(& &1.lodging_amount_cents) |> Enum.sum()

      deposit_due_cents = room_rows |> Enum.map(& &1.deposit_cents) |> Enum.sum()

      group = %Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        status: "active",
        rate_plan: rate_plan,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        rooms: room_rows
      }

      case insert_group(group) do
        {:ok, _group} ->
          {:ok,
           %{
             "group_id" => group.group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           }}

        {:error, :group_already_exists} ->
          {:error, :group_already_exists}
      end
    end
  end

  defp insert_group(group) do
    Repo.insert(group)
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "groups_group_id_index" do
        # Lost a race against another process opening the same group id.
        {:error, :group_already_exists}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp record_cash_payment(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id amount_cents)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_payment_amount(operation["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation) do
      Repo.insert!(%CashMovement{
        group_id: group.id,
        kind: "held",
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })

      group = update_group!(group, [])

      {:ok,
       %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group.id, group.deposit_due_cents),
         "revision" => group.revision
       }}
    end
  end

  defp reschedule_group(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id new_arrival_on)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"], :invalid_stay),
         :ok <- ensure_after(occurred_on, new_arrival_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      group = update_group!(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "revision" => group.revision
       }}
    end
  end

  defp cancel_group(operation) do
    with :ok <- require_fields(operation, ~w(operation_id occurred_on group_id)),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation) do
      paid_cents = Finance.cash_held(group.id)
      refundable? = refundable?(group, occurred_on)

      {refunded_cents, retained_cents} =
        if refundable?, do: {paid_cents, 0}, else: {0, paid_cents}

      if paid_cents > 0 do
        new_kind = if refundable?, do: "refunded", else: "retained"

        Repo.update_all(
          from(m in CashMovement, where: [group_id: ^group.id, kind: "held"]),
          set: [kind: new_kind]
        )
      end

      group = update_group!(group, status: "cancelled")

      {:ok,
       %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "revision" => group.revision
       }}
    end
  end

  # -- Result builders -------------------------------------------------------

  defp success(operation, fields) do
    Map.merge(%{"operation_id" => operation["operation_id"], "status" => "applied"}, fields)
  end

  defp failure(operation, {:stale_revision, group_id, expected, actual}) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    }
  end

  defp failure(operation, code) when is_atom(code) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "rejected",
      "code" => Atom.to_string(code)
    }
  end

  # -- Shared validation steps -----------------------------------------------

  defp require_fields(operation, fields) do
    if Enum.all?(fields, fn field -> present?(Map.get(operation, field)) end) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp present?(value), do: not (is_nil(value) or value == "")

  defp reject_existing_group(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_expected_revision(group, operation) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:error, {:stale_revision, group.group_id, expected, group.revision}}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, :group_not_active}

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_value, code), do: {:error, code}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp ensure_after(occurred_on, date) do
    if Date.compare(date, occurred_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans do
      :ok
    else
      {:error, :invalid_rate_plan}
    end
  end

  defp validate_rooms(rooms) do
    if is_list(rooms) and rooms != [] do
      reduce_rooms(rooms, [], MapSet.new())
    else
      {:error, :invalid_rooms}
    end
  end

  defp reduce_rooms([room | rest], acc, seen_ids) do
    cond do
      not is_map(room) ->
        {:error, :invalid_rooms}

      not valid_room_id?(room["room_id"]) or not valid_rate_cents?(room["nightly_rate_cents"]) ->
        {:error, :invalid_rooms}

      MapSet.member?(seen_ids, room["room_id"]) ->
        {:error, :invalid_rooms}

      true ->
        reduce_rooms(
          rest,
          [{room["room_id"], room["nightly_rate_cents"]} | acc],
          MapSet.put(seen_ids, room["room_id"])
        )
    end
  end

  defp reduce_rooms([], acc, _seen_ids), do: {:ok, Enum.reverse(acc)}

  defp valid_room_id?(room_id), do: is_binary(room_id) and room_id != ""

  defp valid_rate_cents?(rate_cents), do: is_integer(rate_cents) and rate_cents > 0

  defp parse_payment_amount(amount_cents) do
    if is_integer(amount_cents) and amount_cents > 0 do
      {:ok, amount_cents}
    else
      {:error, :invalid_amount}
    end
  end

  defp ensure_within_outstanding(group, amount_cents) do
    outstanding = outstanding_deposit(group.id, group.deposit_due_cents)

    if amount_cents <= outstanding do
      :ok
    else
      {:error, :payment_exceeds_outstanding}
    end
  end

  defp outstanding_deposit(group_id, deposit_due_cents) do
    max(deposit_due_cents - Finance.cash_held(group_id), 0)
  end

  defp refundable?(%Group{rate_plan: "flexible"} = group, cancelled_on) do
    days_before = Date.diff(group.arrival_on, cancelled_on)
    days_before >= @refundable_days_before_arrival
  end

  defp refundable?(_group, _cancelled_on), do: false

  # -- Money -----------------------------------------------------------------

  @doc """
  The deposit required for one room's lodging amount.

  Flexible reservations require a percentage of the lodging amount; advance
  purchase requires the full amount. Percentages round to the nearest cent
  with an exact half-cent rounding upward.
  """
  def deposit_for("flexible", lodging_amount_cents) do
    round_percentage(lodging_amount_cents, @flexible_deposit_percent)
  end

  def deposit_for("advance_purchase", lodging_amount_cents), do: lodging_amount_cents

  defp round_percentage(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  # -- Persistence helpers ---------------------------------------------------

  defp update_group!(group, attrs) do
    group
    |> Ecto.Changeset.change(Map.new(attrs) |> Map.put(:revision, group.revision + 1))
    |> Repo.update!()
  end
end
