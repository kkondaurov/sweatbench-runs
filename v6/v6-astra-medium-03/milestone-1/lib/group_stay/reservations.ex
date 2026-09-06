defmodule GroupStay.Reservations do
  @moduledoc "Processes partner operations atomically, in order, against persisted reservations."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, Repo}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group)
  @public_fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a

  def batch(operations), do: Enum.map(operations, &process/1)

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
    [held, refunded, retained] =
      Repo.one(
        from g in Group,
          select: [
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
            coalesce(sum(g.refunded_cents), 0),
            coalesce(sum(g.retained_cents), 0)
          ]
      )

    %{cash_held_cents: held, cash_refunded_cents: refunded, cash_retained_cents: retained}
  end

  defp process(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil
    # Reserve SQLite's writer before reading revisions; competing writers must observe
    # the committed revision, rather than both validating against the same snapshot.
    {:ok, result} =
      Repo.transaction(
        fn ->
          case validate_common(op) do
            :ok -> dispatch(op)
            {:error, code} -> {:error, code}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, fields} ->
        Map.merge(fields, %{operation_id: id, status: "applied"})

      {:error, code} ->
        %{operation_id: id, status: "rejected", code: code}

      {:stale, group} ->
        %{
          operation_id: id,
          status: "rejected",
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        }
    end
  end

  defp validate_common(op) when is_map(op) do
    if op["type"] in @types and identifier?(op["operation_id"]) and
         identifier?(op["group_id"]) and Map.has_key?(op, "occurred_on"),
       do: :ok,
       else: {:error, "invalid_operation"}
  end

  defp validate_common(_), do: {:error, "invalid_operation"}

  defp dispatch(%{"type" => "open_group"} = op), do: open(op)

  defp dispatch(op) do
    case Repo.get(Group, op["group_id"]) do
      nil ->
        {:error, "group_not_found"}

      group ->
        cond do
          Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
            {:stale, group}

          group.status != "active" ->
            {:error, "group_not_active"}

          true ->
            apply_operation(group, op)
        end
    end
  end

  defp open(op) do
    with :ok <- required(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)),
         true <-
           (identifier?(op["guest_id"]) and identifier?(op["property_id"])) ||
             {:error, "invalid_operation"},
         nil <- Repo.get(Group, op["group_id"]),
         {:ok, booked} <- date(op["occurred_on"], "invalid_stay"),
         {:ok, arrival} <- date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- date(op["departure_on"], "invalid_stay"),
         true <- Date.diff(departure, arrival) > 0 || {:error, "invalid_stay"},
         true <- op["rate_plan"] in ~w(flexible advance_purchase) || {:error, "invalid_rate_plan"},
         :ok <- validate_rooms(op["rooms"]) do
      nights = Date.diff(departure, arrival)
      rooms = Enum.map(op["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents)))
      lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

      due =
        Enum.sum(
          Enum.map(lodging, fn amount ->
            if op["rate_plan"] == "flexible", do: div(amount * 20 + 50, 100), else: amount
          end)
        )

      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          rooms: rooms,
          lodging_total_cents: Enum.sum(lodging),
          deposit_due_cents: due
        })

      success(group, %{deposit_due_cents: due})
    else
      %Group{} -> {:error, "group_already_exists"}
      error -> error
    end
  end

  defp apply_operation(group, %{"type" => "record_cash_payment"} = op) do
    with :ok <- required(op, ["amount_cents"]),
         {:ok, _} <- date(op["occurred_on"], "invalid_operation"),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) ||
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) || {:error, "payment_exceeds_outstanding"} do
      group = update(group, deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"])

      success(group, %{
        amount_cents: op["amount_cents"],
        outstanding_deposit_cents: outstanding(group)
      })
    end
  end

  defp apply_operation(group, %{"type" => "reschedule_group"} = op) do
    with :ok <- required(op, ["new_arrival_on"]),
         {:ok, occurred} <- date(op["occurred_on"], "invalid_stay"),
         {:ok, arrival} <- date(op["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(arrival, occurred) == :gt || {:error, "invalid_stay"} do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
      group = update(group, arrival_on: arrival, departure_on: departure)
      success(group, %{new_arrival_on: arrival, new_departure_on: departure})
    end
  end

  defp apply_operation(group, %{"type" => "cancel_group"} = op) do
    with {:ok, occurred} <- date(op["occurred_on"], "invalid_operation") do
      refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred) >= 14
      refunded = if refundable, do: group.deposit_paid_cents, else: 0
      retained = group.deposit_paid_cents - refunded

      group =
        update(group,
          status: "cancelled",
          deposit_due_cents: 0,
          refunded_cents: refunded,
          retained_cents: retained
        )

      success(group, %{refunded_cents: refunded, retained_cents: retained})
    end
  end

  defp update(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp success(group, fields),
    do: {:ok, Map.merge(fields, %{group_id: group.group_id, revision: group.revision})}

  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required(op, keys) do
    if Enum.all?(keys, &Map.has_key?(op, &1)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp date(_, code), do: {:error, code}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0
      end)

    if valid and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms),
      do: :ok,
      else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}
end
