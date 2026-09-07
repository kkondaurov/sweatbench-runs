defmodule GroupStay.Deposits do
  @moduledoc """
  Owns group deposit reservations and their accounting state.

  Partner operations are deliberately applied in individual transactions. This gives a batch
  ordered visibility while ensuring that one rejected operation cannot partially change a group.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Deposits.{Group, LedgerEntry}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)

  @doc "Processes partner operations in order, committing each successful operation separately."
  def process_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a group with rooms kept in their original partner-supplied order."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  @doc "Returns cash currently held and the cumulative cancellation settlements."
  def ledger do
    totals =
      from(entry in LedgerEntry,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'cash_payment' THEN ? ELSE -? END",
                  entry.kind,
                  entry.amount_cents,
                  entry.amount_cents
                )
              ),
              0
            ),
          cash_refunded_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'refund' THEN ? ELSE 0 END",
                  entry.kind,
                  entry.amount_cents
                )
              ),
              0
            ),
          cash_retained_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'retention' THEN ? ELSE 0 END",
                  entry.kind,
                  entry.amount_cents
                )
              ),
              0
            )
        }
      )
      |> Repo.one()

    Map.new(totals, fn {key, value} -> {key, value || 0} end)
  end

  def outstanding_deposit(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit(%Group{}), do: 0

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      if valid_identifier?(operation_id) do
        case Map.get(operation, "type") do
          "open_group" ->
            transact(fn -> open_group(operation) end)

          "record_cash_payment" ->
            transact(fn -> update_existing(operation, &record_cash_payment/2) end)

          "reschedule_group" ->
            transact(fn -> update_existing(operation, &reschedule_group/2) end)

          "cancel_group" ->
            transact(fn -> update_existing(operation, &cancel_group/2) end)

          _ ->
            {:error, :invalid_operation}
        end
      else
        {:error, :invalid_operation}
      end

    format_result(operation_id, result)
  end

  defp process_operation(_), do: format_result(nil, {:error, :invalid_operation})

  defp transact(fun) do
    case Repo.transaction(
           fn ->
             case fun.() do
               {:ok, value} -> value
               {:error, reason} -> Repo.rollback(reason)
             end
           end,
           mode: :immediate
         ) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_group(operation) do
    with {:ok, attrs} <- open_attributes(operation),
         false <- Repo.exists?(from g in Group, where: g.group_id == ^attrs.group_id),
         {:ok, group} <- insert_group(attrs) do
      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    else
      true -> {:error, :group_already_exists}
      {:error, %Changeset{}} -> {:error, :group_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_attributes(operation) do
    required_ids = ~w(group_id guest_id property_id)

    cond do
      not Enum.all?(required_ids, &valid_identifier?(Map.get(operation, &1))) ->
        {:error, :invalid_operation}

      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "arrival_on") or
        not Map.has_key?(operation, "departure_on") or not Map.has_key?(operation, "rooms") or
          not Map.has_key?(operation, "rate_plan") ->
        {:error, :invalid_operation}

      true ->
        build_open_attributes(operation)
    end
  end

  defp build_open_attributes(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"], :invalid_stay),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], :invalid_stay),
         {:ok, departure_on} <- parse_date(operation["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights <- Date.diff(departure_on, arrival_on),
         {lodging_total, deposit_due} <- totals(rooms, nights, operation["rate_plan"]) do
      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: operation["rate_plan"],
         rooms: rooms,
         lodging_total_cents: lodging_total,
         deposit_due_cents: deposit_due
       }}
    end
  end

  defp insert_group(attrs) do
    room_attrs = Enum.with_index(attrs.rooms, &Map.put(&1, :position, &2))
    insert_attrs = attrs |> Map.delete(:rooms) |> Map.put(:rooms, room_attrs)

    %Group{}
    |> Changeset.cast(insert_attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> Changeset.put_change(:status, "active")
    |> Changeset.put_change(:revision, 1)
    |> Changeset.cast_assoc(:rooms,
      with: fn room, params ->
        Changeset.cast(room, params, [:room_id, :nightly_rate_cents, :position])
      end
    )
    |> Changeset.unique_constraint(:group_id)
    |> Repo.insert()
  end

  defp update_existing(operation, update_fun) do
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> {:error, :group_not_found}
        group -> check_revision_then_update(group, operation, update_fun)
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp check_revision_then_update(group, operation, update_fun) do
    case Map.fetch(operation, "expected_revision") do
      {:ok, expected} when is_integer(expected) and expected !== group.revision ->
        {:error, {:stale_revision, group.group_id, expected, group.revision}}

      {:ok, expected} when is_integer(expected) ->
        apply_complete_operation(operation, group, update_fun)

      :error ->
        apply_complete_operation(operation, group, update_fun)

      {:ok, _invalid_revision} ->
        {:error, :invalid_operation}
    end
  end

  defp apply_complete_operation(operation, group, update_fun) do
    if structurally_complete?(operation) do
      update_fun.(group, operation)
    else
      {:error, :invalid_operation}
    end
  end

  defp structurally_complete?(%{"type" => "record_cash_payment"} = operation),
    do: Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")

  defp structurally_complete?(%{"type" => "reschedule_group"} = operation),
    do: Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on")

  defp structurally_complete?(%{"type" => "cancel_group"} = operation),
    do: Map.has_key?(operation, "occurred_on")

  defp structurally_complete?(_operation), do: false

  defp record_cash_payment(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         true <- amount <= outstanding_deposit(group),
         {:ok, _entry} <-
           insert_ledger_entry(group, operation, occurred_on, "cash_payment", amount) do
      group
      |> Changeset.change(
        deposit_paid_cents: group.deposit_paid_cents + amount,
        revision: group.revision + 1
      )
      |> Repo.update()
      |> applied(fn updated ->
        %{
          group_id: updated.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(updated),
          revision: updated.revision
        }
      end)
    else
      false -> {:error, :payment_exceeds_outstanding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reschedule_group(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, new_arrival} <- reschedule_date(operation),
         true <- Date.after?(new_arrival, occurred_on) do
      days = Date.diff(new_arrival, group.arrival_on)
      new_departure = Date.add(group.departure_on, days)

      group
      |> Changeset.change(
        arrival_on: new_arrival,
        departure_on: new_departure,
        revision: group.revision + 1
      )
      |> Repo.update()
      |> applied(fn updated ->
        %{
          group_id: updated.group_id,
          new_arrival_on: updated.arrival_on,
          new_departure_on: updated.departure_on,
          revision: updated.revision
        }
      end)
    else
      false -> {:error, :invalid_stay}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_group(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group) do
      refundable =
        group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

      refunded = if refundable, do: group.deposit_paid_cents, else: 0
      retained = if refundable, do: 0, else: group.deposit_paid_cents

      settlement = if refundable, do: {"refund", refunded}, else: {"retention", retained}

      with :ok <- insert_settlement(group, operation, occurred_on, settlement) do
        group
        |> Changeset.change(
          status: "cancelled",
          refunded_cents: refunded,
          retained_cents: retained,
          revision: group.revision + 1
        )
        |> Repo.update()
        |> applied(fn updated ->
          %{
            group_id: updated.group_id,
            refunded_cents: refunded,
            retained_cents: retained,
            revision: updated.revision
          }
        end)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reschedule_date(operation) do
    if Map.has_key?(operation, "new_arrival_on") do
      parse_date(operation["new_arrival_on"], :invalid_stay)
    else
      {:error, :invalid_operation}
    end
  end

  defp payment_amount(operation) do
    if Map.has_key?(operation, "amount_cents") do
      case operation["amount_cents"] do
        amount when is_integer(amount) and amount > 0 -> {:ok, amount}
        _ -> {:error, :invalid_amount}
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp insert_settlement(_group, _operation, _occurred_on, {_kind, 0}), do: :ok

  defp insert_settlement(group, operation, occurred_on, {kind, amount}) do
    case insert_ledger_entry(group, operation, occurred_on, kind, amount) do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_ledger_entry(group, operation, occurred_on, kind, amount) do
    %LedgerEntry{}
    |> Changeset.cast(
      %{
        group_id: group.id,
        operation_id: operation["operation_id"],
        occurred_on: occurred_on,
        kind: kind,
        amount_cents: amount
      },
      [:group_id, :operation_id, :occurred_on, :kind, :amount_cents]
    )
    |> Repo.insert()
  end

  defp validate_stay(arrival, departure) do
    if Date.before?(arrival, departure), do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, :invalid_rate_plan}
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          valid_identifier?(room_id) and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    identifiers = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(identifiers) == identifiers do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp totals(rooms, nights, rate_plan) do
    lodging = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
    lodging_total = Enum.sum(lodging)

    deposit_due =
      case rate_plan do
        "flexible" -> Enum.sum(Enum.map(lodging, &div(&1 * 20 + 50, 100)))
        "advance_purchase" -> lodging_total
      end

    {lodging_total, deposit_due}
  end

  defp parse_date(value, error) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, error}
    end
  end

  defp parse_date(_, error), do: {:error, error}

  defp active(%Group{status: "active"}), do: :ok
  defp active(%Group{}), do: {:error, :group_not_active}

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp applied({:ok, value}, formatter), do: {:ok, formatter.(value)}
  defp applied({:error, changeset}, _formatter), do: {:error, changeset}

  defp format_result(operation_id, {:ok, fields}) do
    fields |> Map.put(:operation_id, operation_id) |> Map.put(:status, "applied")
  end

  defp format_result(operation_id, {:error, {:stale_revision, group_id, expected, actual}}) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    }
  end

  defp format_result(operation_id, {:error, %Changeset{}}) do
    format_result(operation_id, {:error, :invalid_operation})
  end

  defp format_result(operation_id, {:error, code}) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end
end
