defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations independently and in order.

  Each operation takes SQLite's write lock before reading the group, making revision
  checks and settlement writes atomic across requests. Finance totals are derived
  from persisted group settlements, so no separate ledger balance can drift.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Policy}
  alias GroupStay.Credits

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)

  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()) do
    # Keep cash and credit totals on the same database snapshot during concurrent writes.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents - g.credit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0),
          cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
        }
    )
    |> Map.put(:credit_liability_cents, Credits.liability(on))
  end

  def process_batch(operations), do: Enum.map(operations, &process/1)

  defp process(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    result =
      Repo.transaction(
        fn ->
          with :ok <- validate_operation(operation),
               {:ok, result} <- apply_operation(operation) do
            result
          else
            {:error, code} when is_binary(code) -> Repo.rollback(%{code: code})
            {:error, details} -> Repo.rollback(details)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "applied"})
      {:error, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp validate_operation(op) when is_map(op) do
    required =
      case op["type"] do
        "open_group" -> ~w(guest_id property_id arrival_on departure_on rate_plan rooms)
        type when type in ~w(record_cash_payment apply_hotel_credit) -> ["amount_cents"]
        "reschedule_group" -> ["new_arrival_on"]
        _ -> []
      end

    if op["type"] in @types and
         Enum.all?(~w(operation_id group_id), &identifier?(op[&1])) and
         Map.has_key?(op, "occurred_on") and
         Enum.all?(required, &Map.has_key?(op, &1)) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_operation(_), do: {:error, "invalid_operation"}

  defp apply_operation(%{"type" => "open_group"} = op) do
    cond do
      get_group(op["group_id"]) != nil ->
        {:error, "group_already_exists"}

      not identifier?(op["guest_id"]) or not identifier?(op["property_id"]) ->
        {:error, "invalid_operation"}

      true ->
        open_group(op)
    end
  end

  defp apply_operation(op) do
    case get_group(op["group_id"]) do
      nil ->
        {:error, "group_not_found"}

      group ->
        cond do
          Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
            {:error,
             %{
               code: "stale_revision",
               group_id: group.group_id,
               expected_revision: op["expected_revision"],
               actual_revision: group.revision
             }}

          group.status != "active" ->
            {:error, "group_not_active"}

          true ->
            update_group(group, op)
        end
    end
  end

  defp open_group(op) do
    with {:ok, booked} <- date(op["occurred_on"]),
         {:ok, arrival} <- date(op["arrival_on"]),
         {:ok, departure} <- date(op["departure_on"]),
         :ok <- require_valid(Date.diff(departure, arrival) > 0, "invalid_stay"),
         :ok <- require_valid(valid_rooms?(op["rooms"]), "invalid_rooms"),
         :ok <-
           require_valid(op["rate_plan"] in ~w(flexible advance_purchase), "invalid_rate_plan") do
      nights = Date.diff(departure, arrival)
      amounts = Enum.map(op["rooms"], &(&1["nightly_rate_cents"] * nights))

      deposit =
        if op["rate_plan"] == "flexible",
          do: Enum.sum(Enum.map(amounts, &flexible_deposit/1)),
          else: Enum.sum(amounts)

      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: Policy.version(op["rate_plan"], booked),
          rooms: Enum.map(op["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents))),
          lodging_total_cents: Enum.sum(amounts),
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    end
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = op) do
    amount = op["amount_cents"]

    with {:ok, _} <- date(op["occurred_on"]),
         :ok <- require_valid(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- require_valid(amount <= Group.outstanding(group), "payment_exceeds_outstanding") do
      save(group, %{deposit_paid_cents: group.deposit_paid_cents + amount}, %{
        amount_cents: amount,
        outstanding_deposit_cents: Group.outstanding(group) - amount
      })
    end
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = op) do
    amount = op["amount_cents"]

    with {:ok, occurred} <- date(op["occurred_on"]),
         :ok <- require_valid(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- require_valid(amount <= Group.outstanding(group), "payment_exceeds_outstanding"),
         :ok <- Credits.apply(group, amount, occurred) do
      save(
        group,
        %{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount
        },
        %{
          amount_cents: amount,
          outstanding_deposit_cents: Group.outstanding(group) - amount
        }
      )
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = op) do
    with {:ok, occurred} <- date(op["occurred_on"]),
         {:ok, arrival} <- date(op["new_arrival_on"]),
         :ok <- require_valid(Date.compare(arrival, occurred) == :gt, "invalid_stay") do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

      save(group, %{arrival_on: arrival, departure_on: departure}, %{
        new_arrival_on: arrival,
        new_departure_on: departure,
        policy_version: group.policy_version,
        refundable_until: Policy.refundable_until(%{group | arrival_on: arrival})
      })
    end
  end

  defp update_group(group, %{"type" => "cancel_group"} = op) do
    method = Map.get(op, "refund_method", "cash")

    with {:ok, occurred} <- date(op["occurred_on"]),
         :ok <- require_valid(method in ~w(cash hotel_credit), "invalid_operation"),
         refundable = Policy.refundable?(group, occurred),
         :ok <-
           require_valid(method != "hotel_credit" or refundable, "refund_method_not_available") do
      cash = Group.cash_paid(group)
      converted = if method == "hotel_credit", do: cash, else: 0
      issued = Credits.issue(group, op["operation_id"], converted, occurred)
      Credits.settle(group, refundable, occurred)

      settlement = %{
        refunded_cents: if(refundable and method == "cash", do: cash, else: 0),
        retained_cents: if(refundable, do: 0, else: cash)
      }

      changes =
        Map.merge(settlement, %{
          status: "cancelled",
          deposit_due_cents: 0,
          cash_converted_to_credit_cents: converted
        })

      save(group, changes, Map.put(settlement, :credit_issued_cents, issued))
    end
  end

  defp save(group, changes, result) do
    revision = group.revision + 1
    group |> Ecto.Changeset.change(Map.put(changes, :revision, revision)) |> Repo.update!()
    {:ok, Map.merge(result, %{group_id: group.group_id, revision: revision})}
  end

  # Round each room independently using integer arithmetic; ties round upward.
  defp flexible_deposit(lodging_cents), do: div(lodging_cents * 20 + 50, 100)

  defp identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp date(_), do: {:error, "invalid_stay"}
  defp require_valid(true, _), do: :ok
  defp require_valid(false, code), do: {:error, code}

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      is_map(room) and identifier?(room["room_id"]) and
        is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0
    end) and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
end
