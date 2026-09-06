defmodule GroupStay.Reservations do
  @moduledoc "Applies partner operations atomically and owns reservation deposit accounting."

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @max_integer 9_223_372_036_854_775_807
  @public_fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def ledger do
    # Sum with Elixir integers: combined cash across groups can exceed SQLite's
    # signed 64-bit SUM even though each stored amount fits in an integer column.
    Repo.all(from g in Group, select: {g.deposit_paid_cents, g.refunded_cents, g.retained_cents})
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn {held, refunded, retained}, totals ->
        %{
          cash_held_cents: totals.cash_held_cents + held,
          cash_refunded_cents: totals.cash_refunded_cents + refunded,
          cash_retained_cents: totals.cash_retained_cents + retained
        }
      end
    )
  end

  defp apply_operation(op) do
    # SQLite's write lock is acquired before reading the revision. Concurrent
    # requests therefore cannot both validate and spend the same outstanding cash.
    {:ok, result} = Repo.transaction(fn -> execute(op) end, mode: :immediate)
    result
  end

  defp execute(op) when is_map(op) do
    with :ok <- common_fields(op),
         {:ok, occurred_on} <- date(op["occurred_on"], "invalid_operation"),
         {:ok, result} <- dispatch(op, occurred_on) do
      Map.merge(result, %{operation_id: op["operation_id"], status: "applied"})
    else
      {:error, code} when is_binary(code) -> reject(op, %{code: code})
      {:error, details} -> reject(op, details)
    end
  end

  defp execute(_), do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp reject(op, details),
    do: Map.merge(details, %{operation_id: op["operation_id"], status: "rejected"})

  defp common_fields(op) do
    if op["type"] in @types and Enum.all?(~w(operation_id group_id), &identifier?(op[&1])),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "open_group"} = op, occurred_on) do
    with :ok <- required(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)),
         true <-
           (identifier?(op["guest_id"]) and identifier?(op["property_id"])) or
             {:error, "invalid_operation"},
         nil <- Repo.get(Group, op["group_id"]),
         {:ok, arrival} <- date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- date(op["departure_on"], "invalid_stay"),
         true <- Date.compare(departure, arrival) == :gt or {:error, "invalid_stay"},
         true <- op["rate_plan"] in ~w(flexible advance_purchase) or {:error, "invalid_rate_plan"},
         {:ok, rooms, lodging, deposit} <-
           price_rooms(op["rooms"], Date.diff(departure, arrival), op["rate_plan"]) do
      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: occurred_on,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          rooms: rooms,
          lodging_total_cents: lodging,
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    else
      %Group{} -> {:error, "group_already_exists"}
      error -> error
    end
  end

  defp dispatch(op, occurred_on) do
    with %Group{} = group <- Repo.get(Group, op["group_id"]),
         :ok <- check_revision(op, group),
         true <- group.status == "active" or {:error, "group_not_active"} do
      update_group(op, group, occurred_on)
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp check_revision(op, group) do
    if not Map.has_key?(op, "expected_revision") or op["expected_revision"] === group.revision do
      :ok
    else
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: op["expected_revision"],
         actual_revision: group.revision
       }}
    end
  end

  defp update_group(%{"type" => "record_cash_payment"} = op, group, _date) do
    with :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) or {:error, "payment_exceeds_outstanding"} do
      updated = persist(group, deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"])

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: op["amount_cents"],
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "reschedule_group"} = op, group, occurred_on) do
    with :ok <- required(op, ~w(new_arrival_on)),
         {:ok, arrival} <- date(op["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(arrival, occurred_on) == :gt or {:error, "invalid_stay"},
         {:ok, departure} <- shifted_departure(arrival, group) do
      updated = persist(group, arrival_on: arrival, departure_on: departure)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: arrival,
         new_departure_on: departure,
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "cancel_group"}, group, occurred_on) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.deposit_paid_cents

    updated =
      persist(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        refunded_cents: refunded,
        retained_cents: retained
      )

    {:ok,
     %{
       group_id: group.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       revision: updated.revision
     }}
  end

  defp persist(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required(op, keys) do
    if Enum.all?(keys, &Map.has_key?(op, &1)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> {:error, code}
    end
  end

  defp date(_, code), do: {:error, code}

  defp shifted_departure(arrival, group) do
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    if departure.year in -9999..9999,
      do: {:ok, departure},
      else: {:error, "invalid_stay"}
  end

  defp price_rooms(rooms, nights, plan) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) and is_integer(rate) and rate >= 0

        _ ->
          false
      end)

    if valid and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
      # Integer arithmetic implements half-up rounding without floating point loss.
      deposit =
        Enum.sum(
          Enum.map(lodging, fn amount ->
            if plan == "flexible", do: div(amount * 20 + 50, 100), else: amount
          end)
        )

      total = Enum.sum(lodging)

      if total <= @max_integer do
        {:ok, Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))), total, deposit}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp price_rooms(_, _, _), do: {:error, "invalid_rooms"}
end
