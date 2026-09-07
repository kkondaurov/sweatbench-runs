defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Owns the durable inception point and movement journal for daily finance reports.

  Reporting records accounting deltas alongside the partner operation that
  caused them. Reports fold those immutable deltas from the opening position;
  reading a report consequently has no side effects. Credit-lot deltas are
  retained even when applying or restoring credit has no liability movement,
  because they determine how much unused credit expires on a later day.
  """

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Credits.CreditLot

  alias GroupStay.FinanceReporting.{
    CashOpeningBalance,
    CreditLotOpeningBalance,
    OperationMovement,
    Report,
    ReportingStart
  }

  alias GroupStay.Repo
  alias GroupStay.Reservations.{DepositPolicy, Group}

  @start_id 1
  @cash_fields ~w(
    received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents
    converted_to_credit_cents reduced_cents charged_back_cents
  )
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @tracked_types ~w(
    record_cash_payment apply_hotel_credit cancel_group cancel_rooms reduce_cash_payment
    charge_back_payment transfer_deposit
  )

  @doc "Starts reporting from a snapshot of the current financial position."
  def start(starts_on) do
    case Repo.get(ReportingStart, @start_id) do
      nil ->
        cash = cash_opening_balances()
        credit_lots = credit_lot_state()

        %ReportingStart{}
        |> ReportingStart.changeset(%{
          id: @start_id,
          starts_on: starts_on,
          opening_credit_liability_cents: Credits.liability_cents(starts_on)
        })
        |> Repo.insert!()

        Enum.each(cash, fn {property_id, held_cents} ->
          %CashOpeningBalance{}
          |> CashOpeningBalance.changeset(%{
            property_id: property_id,
            opening_held_cents: held_cents
          })
          |> Repo.insert!()
        end)

        Enum.each(credit_lots, fn {lot_id, lot} ->
          %CreditLotOpeningBalance{}
          |> CreditLotOpeningBalance.changeset(%{
            credit_lot_record_id: lot_id,
            expires_on: lot.expires_on,
            remaining_cents: lot.remaining_cents,
            allocated_cents: lot.allocated_cents
          })
          |> Repo.insert!()
        end)

        :ok

      %ReportingStart{} ->
        {:error, :reporting_already_started}
    end
  end

  @doc "Runs an operation and journals its finance effects when reporting is active."
  def track(%{"type" => type} = operation, fun) when type in @tracked_types do
    case {Repo.get(ReportingStart, @start_id), parse_date(operation["occurred_on"])} do
      {%ReportingStart{} = start, {:ok, occurred_on}} ->
        posting_date = later_of(occurred_on, start.starts_on)
        before = financial_state(operation, occurred_on)
        result = fun.()
        after_state = financial_state(operation, occurred_on)

        if applied?(result) do
          record_movement!(operation, posting_date, before, after_state)
        end

        result

      _ ->
        fun.()
    end
  end

  def track(_operation, fun), do: fun.()

  @doc "Builds the open daily report for a date at or after reporting inception."
  def daily_report(date) do
    case Repo.get(ReportingStart, @start_id) do
      nil ->
        {:error, :report_not_available}

      %ReportingStart{} = start ->
        if Date.before?(date, start.starts_on) do
          {:error, :report_not_available}
        else
          {:ok, Report.build(start, date)}
        end
    end
  end

  defp financial_state(operation, occurred_on) do
    %{
      cash: cash_group_state(),
      credit_lots: credit_lot_state(),
      cancellation_refundable?: cancellation_refundable?(operation, occurred_on)
    }
  end

  defp cash_group_state do
    Group
    |> Repo.all()
    |> Map.new(fn group ->
      {group.id,
       %{
         group_id: group.group_id,
         property_id: group.property_id,
         held_cents: if(group.status == "active", do: group.cash_paid_cents, else: 0),
         refunded_cents: group.refunded_cents,
         retained_cents: group.retained_cents,
         converted_to_credit_cents: group.cash_converted_to_credit_cents
       }}
    end)
  end

  defp cash_opening_balances do
    cash_group_state()
    |> Map.values()
    |> Enum.group_by(& &1.property_id)
    |> Map.new(fn {property_id, groups} ->
      {property_id, Enum.sum(Enum.map(groups, & &1.held_cents))}
    end)
    |> Map.reject(fn {_property_id, amount} -> amount == 0 end)
  end

  defp credit_lot_state do
    CreditLot
    |> preload(:allocations)
    |> Repo.all()
    |> Map.new(fn lot ->
      {lot.id,
       %{
         expires_on: lot.expires_on,
         remaining_cents: lot.remaining_cents,
         allocated_cents: Enum.sum(Enum.map(lot.allocations, & &1.amount_cents)),
         clawback_cents: lot.unrecovered_clawback_cents
       }}
    end)
  end

  defp cancellation_refundable?(%{"type" => type, "group_id" => group_id}, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> false
      group -> DepositPolicy.refundable?(group, occurred_on)
    end
  end

  defp cancellation_refundable?(_operation, _occurred_on), do: false

  defp record_movement!(operation, posting_date, before, after_state) do
    %OperationMovement{}
    |> OperationMovement.changeset(%{
      operation_id: operation["operation_id"],
      posting_date: posting_date,
      cash: cash_movements(operation, before.cash, after_state.cash),
      credit:
        credit_movements(
          operation,
          posting_date,
          before.credit_lots,
          after_state.credit_lots,
          before.cancellation_refundable?
        ),
      credit_lot_deltas: %{
        "entries" => credit_lot_deltas(before.credit_lots, after_state.credit_lots)
      }
    })
    |> Repo.insert!()
  end

  defp cash_movements(%{"type" => "record_cash_payment"}, before, after_state) do
    group_differences(before, after_state, fn old, new ->
      [{"received_cents", new.held_cents - old.held_cents}]
    end)
  end

  defp cash_movements(%{"type" => "transfer_deposit"} = operation, before, after_state) do
    empty_cash()
    |> add_group_cash(
      find_group(before, operation["source_group_id"]),
      "transferred_out_cents",
      held_decrease(before, after_state, operation["source_group_id"])
    )
    |> add_group_cash(
      find_group(after_state, operation["destination_group_id"]),
      "transferred_in_cents",
      held_increase(before, after_state, operation["destination_group_id"])
    )
    |> drop_empty_properties()
  end

  defp cash_movements(%{"type" => type}, before, after_state)
       when type in ["cancel_group", "cancel_rooms"] do
    group_differences(before, after_state, fn old, new ->
      [
        {"refunded_cents", new.refunded_cents - old.refunded_cents},
        {"retained_cents", new.retained_cents - old.retained_cents},
        {"converted_to_credit_cents",
         new.converted_to_credit_cents - old.converted_to_credit_cents}
      ]
    end)
  end

  defp cash_movements(%{"type" => "reduce_cash_payment"}, before, after_state) do
    group_differences(before, after_state, fn old, new ->
      [{"reduced_cents", old.held_cents - new.held_cents}]
    end)
  end

  defp cash_movements(%{"type" => "charge_back_payment"}, before, after_state) do
    group_differences(before, after_state, fn old, new ->
      refunded = new.refunded_cents - old.refunded_cents
      retained = new.retained_cents - old.retained_cents
      converted = new.converted_to_credit_cents - old.converted_to_credit_cents
      held_change = new.held_cents - old.held_cents

      [
        {"refunded_cents", refunded},
        {"retained_cents", retained},
        {"converted_to_credit_cents", converted},
        {"charged_back_cents", -held_change - refunded - retained - converted}
      ]
    end)
  end

  defp cash_movements(_operation, _before, _after_state), do: %{}

  defp group_differences(before, after_state, fields_fun) do
    Map.keys(before)
    |> Kernel.++(Map.keys(after_state))
    |> Enum.uniq()
    |> Enum.reduce(empty_cash(), fn id, cash ->
      template = Map.get(before, id) || Map.fetch!(after_state, id)
      old = Map.get(before, id, zero_group(template))
      new = Map.get(after_state, id, zero_group(template))

      Enum.reduce(fields_fun.(old, new), cash, fn {field, amount}, cash ->
        add_group_cash(cash, new, field, amount)
      end)
    end)
    |> drop_empty_properties()
  end

  defp zero_group(group) do
    Map.merge(group, %{
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0
    })
  end

  defp find_group(groups, group_id) do
    Enum.find_value(groups, fn {_id, group} -> if group.group_id == group_id, do: group end)
  end

  defp held_decrease(before, after_state, group_id) do
    old = find_group(before, group_id)
    new = find_group(after_state, group_id)
    max(old.held_cents - new.held_cents, 0)
  end

  defp held_increase(before, after_state, group_id) do
    old = find_group(before, group_id)
    new = find_group(after_state, group_id)
    max(new.held_cents - old.held_cents, 0)
  end

  defp add_group_cash(cash, _group, _field, 0), do: cash

  defp add_group_cash(cash, group, field, amount) do
    Map.update(
      cash,
      group.property_id,
      Map.put(zero_cash_movements(), field, amount),
      &Map.update!(&1, field, fn current -> current + amount end)
    )
  end

  defp empty_cash, do: %{}

  defp drop_empty_properties(cash) do
    Map.reject(cash, fn {_property_id, movements} -> all_zero?(movements) end)
  end

  defp credit_movements(operation, posting_date, before, after_state, refundable?) do
    movements = zero_credit_movements()

    movements =
      case operation["type"] do
        type when type in ["cancel_group", "cancel_rooms"] ->
          cancellation_credit_movements(
            movements,
            posting_date,
            before,
            after_state,
            refundable?
          )

        "charge_back_payment" ->
          revoked =
            credit_liability(before, posting_date) - credit_liability(after_state, posting_date)

          Map.put(movements, "revoked_cents", max(revoked, 0))

        _ ->
          movements
      end

    movements
  end

  defp cancellation_credit_movements(movements, posting_date, before, after_state, true) do
    {issued, issued_expired} =
      after_state
      |> Enum.reject(fn {id, _lot} -> Map.has_key?(before, id) end)
      |> Enum.reduce({0, 0}, fn {_id, lot}, {issued, expired} ->
        immediately_expired =
          if Date.before?(lot.expires_on, posting_date), do: lot.remaining_cents, else: 0

        {issued + lot.remaining_cents, expired + immediately_expired}
      end)

    {restored_expired, absorbed} =
      before
      |> Enum.filter(fn {id, _lot} -> Map.has_key?(after_state, id) end)
      |> Enum.reduce({0, 0}, fn {id, old}, {expired, absorbed} ->
        new = Map.fetch!(after_state, id)
        remaining_drop = max(old.remaining_cents - new.remaining_cents, 0)
        lot_absorbed = min(max(old.clawback_cents - new.clawback_cents, 0), remaining_drop)
        {expired + remaining_drop - lot_absorbed, absorbed + lot_absorbed}
      end)

    movements
    |> Map.put("issued_cents", issued)
    |> Map.put("expired_cents", issued_expired + restored_expired)
    |> Map.put("absorbed_cents", absorbed)
  end

  defp cancellation_credit_movements(movements, _posting_date, before, after_state, false) do
    consumed =
      Enum.reduce(before, 0, fn {id, old}, total ->
        case Map.get(after_state, id) do
          nil -> total
          new -> total + max(old.remaining_cents - new.remaining_cents, 0)
        end
      end)

    Map.put(movements, "consumed_cents", consumed)
  end

  defp credit_liability(lots, on) do
    Enum.reduce(lots, 0, fn {_id, lot}, total ->
      liability =
        if Date.before?(lot.expires_on, on), do: lot.allocated_cents, else: lot.remaining_cents

      total + liability
    end)
  end

  defp credit_lot_deltas(before, after_state) do
    Map.keys(before)
    |> Kernel.++(Map.keys(after_state))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      old = Map.get(before, id, %{remaining_cents: 0, allocated_cents: 0})
      new = Map.get(after_state, id, %{remaining_cents: 0, allocated_cents: 0})
      remaining = new.remaining_cents - old.remaining_cents
      allocated = new.allocated_cents - old.allocated_cents

      if remaining == 0 and allocated == 0 do
        []
      else
        lot = Map.get(after_state, id) || Map.fetch!(before, id)

        [
          %{
            "credit_lot_record_id" => id,
            "expires_on" => Date.to_iso8601(lot.expires_on),
            "remaining_cents" => remaining,
            "allocated_cents" => allocated
          }
        ]
      end
    end)
  end

  defp zero_cash_movements, do: Map.new(@cash_fields, &{&1, 0})
  defp zero_credit_movements, do: Map.new(@credit_fields, &{&1, 0})
  defp all_zero?(movements), do: Enum.all?(movements, fn {_field, amount} -> amount == 0 end)

  defp applied?(%{status: "applied"}), do: true
  defp applied?(%{"status" => "applied"}), do: true
  defp applied?(_result), do: false

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp later_of(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
