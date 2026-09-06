defmodule GroupStay.Reservations do
  @moduledoc "Applies ordered partner operations and maintains reservation deposit accounting."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, Repo}

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status rooms revision lodging_total_cents deposit_due_cents deposit_paid_cents)a
  @required %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => []
  }

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group |> Map.take(@fields) |> Map.put(:outstanding_deposit_cents, outstanding(group))
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

  defp apply_operation(op) do
    operation_id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # Acquire SQLite's write reservation before reading the revision. Other writers
    # cannot slip between the revision check and the accounting update.
    {:ok, result} =
      Repo.transaction(
        fn ->
          with :ok <- validate_operation(op),
               {:ok, fields} <- dispatch(op) do
            Map.merge(fields, %{status: "applied"})
          else
            {:error, code} ->
              %{status: "rejected", code: code}

            {:stale, group} ->
              %{
                status: "rejected",
                code: "stale_revision",
                group_id: group.group_id,
                expected_revision: op["expected_revision"],
                actual_revision: group.revision
              }
          end
        end,
        mode: :immediate
      )

    Map.put(result, :operation_id, operation_id)
  end

  defp validate_operation(op) when is_map(op) do
    required = Map.get(@required, op["type"])

    if required != nil and Enum.all?(~w(operation_id group_id), &identifier?(op[&1])) and
         Map.has_key?(op, "occurred_on") and Enum.all?(required, &Map.has_key?(op, &1)) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_operation(_), do: {:error, "invalid_operation"}

  defp dispatch(%{"type" => "open_group"} = op) do
    cond do
      Repo.get(Group, op["group_id"]) != nil ->
        {:error, "group_already_exists"}

      not identifier?(op["guest_id"]) or not identifier?(op["property_id"]) ->
        {:error, "invalid_operation"}

      true ->
        open(op)
    end
  end

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
            with {:ok, occurred_on} <- parse_date(op["occurred_on"], "invalid_operation") do
              change(group, op, occurred_on)
            end
        end
    end
  end

  defp open(op) do
    with {:ok, booked} <- parse_date(op["occurred_on"], "invalid_operation"),
         {:ok, arrival} <- parse_date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- parse_date(op["departure_on"], "invalid_stay"),
         :ok <- ensure(Date.diff(departure, arrival) > 0, "invalid_stay"),
         :ok <- ensure(valid_rooms?(op["rooms"]), "invalid_rooms"),
         :ok <- ensure(op["rate_plan"] in ["flexible", "advance_purchase"], "invalid_rate_plan") do
      rooms = Enum.map(op["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents)))
      amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * Date.diff(departure, arrival)))

      due =
        Enum.sum(
          Enum.map(amounts, fn amount ->
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
          lodging_total_cents: Enum.sum(amounts),
          deposit_due_cents: due
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}}
    end
  end

  defp change(group, %{"type" => "record_cash_payment"} = op, _) do
    amount = op["amount_cents"]

    with :ok <- ensure(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- ensure(amount <= outstanding(group), "payment_exceeds_outstanding") do
      updated = update(group, deposit_paid_cents: group.deposit_paid_cents + amount)

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp change(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    with {:ok, arrival} <- parse_date(op["new_arrival_on"], "invalid_stay"),
         :ok <- ensure(Date.compare(arrival, occurred_on) == :gt, "invalid_stay") do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
      updated = update(group, arrival_on: arrival, departure_on: departure)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: arrival,
         new_departure_on: departure,
         revision: updated.revision
       }}
    end
  end

  defp change(group, %{"type" => "cancel_group"}, occurred_on) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    updated =
      update(group, status: "cancelled", refunded_cents: refunded, retained_cents: retained)

    {:ok,
     %{
       group_id: group.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       revision: updated.revision
     }}
  end

  defp update(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp ensure(true, _), do: :ok
  defp ensure(false, code), do: {:error, code}

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      is_map(room) and identifier?(room["room_id"]) and
        is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0
    end) and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
end
