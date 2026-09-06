defmodule GroupStay.Finance do
  @moduledoc """
  Durable finance reporting.

  Reporting begins with the first applied `start_finance_reporting`
  operation, which freezes the opening position on `starts_on`. From then
  on, every finance effect of an applied operation is recorded as an event
  posted on the later of its `occurred_on` and `starts_on`, so reports stay
  reproducible and reading them never touches domain state. Natural credit
  expiries happen without partner operations and are derived from the
  per-lot event history and the lot state frozen at inception.
  """

  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo
  alias GroupStay.Finance.Event
  alias GroupStay.Finance.LotEvent
  alias GroupStay.Finance.Reporting

  @cash_classes ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_classes ~w(issued expired consumed revoked absorbed)

  @doc """
  Starts finance reporting on `starts_on`, freezing the financial position
  immediately before this call as the opening position. Fails with
  `:reporting_already_started` once an inception point exists.
  """
  def start_reporting(starts_on) do
    case current_reporting() do
      %Reporting{} ->
        {:error, :reporting_already_started}

      nil ->
        snapshot = Groups.credit_reporting_snapshot(starts_on)

        Repo.insert!(%Reporting{
          starts_on: starts_on,
          opening_liability_cents: snapshot.liability_cents,
          opening_cash_held_cents: held_cash_by_property(),
          lot_snapshot: snapshot.lots
        })

        {:ok, starts_on}
    end
  end

  @doc """
  Records finance effects of an applied domain operation. Entries are:

    * `%{kind: :cash, property_id:, classification:, amount_cents:}` -
      a signed cash movement attributed to a property;
    * `%{kind: :credit, classification:, amount_cents:}` - a company-wide
      credit liability movement;
    * `%{kind: :lot, credit_lot_id:, remaining_delta_cents:,
      funded_delta_cents:}` - a per-lot balance change kept only to derive
      natural expiries.

  Does nothing before reporting has started. Every effect is posted on the
  later of the operation's `occurred_on` and the reporting start date.
  """
  def record!(entries, occurred_on) when is_list(entries) do
    case current_reporting() do
      nil ->
        :ok

      %Reporting{starts_on: starts_on} ->
        posted_on = later_date(starts_on, occurred_on)

        Enum.each(entries, fn
          %{kind: :cash} = entry ->
            Repo.insert!(%Event{
              posted_on: posted_on,
              scope: "cash",
              classification: entry.classification,
              property_id: entry.property_id,
              amount_cents: entry.amount_cents
            })

          %{kind: :credit} = entry ->
            Repo.insert!(%Event{
              posted_on: posted_on,
              scope: "credit",
              classification: entry.classification,
              property_id: nil,
              amount_cents: entry.amount_cents
            })

          %{kind: :lot} = entry ->
            Repo.insert!(%LotEvent{
              posted_on: posted_on,
              credit_lot_id: entry.credit_lot_id,
              remaining_delta_cents: entry.remaining_delta_cents,
              funded_delta_cents: entry.funded_delta_cents
            })
        end)

        :ok
    end
  end

  @doc """
  The daily report for `date`, or `:error` before reporting has started or
  for a date before `starts_on`. Reading never changes state.
  """
  def daily_report(date) do
    case current_reporting() do
      nil ->
        :error

      %Reporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          :error
        else
          {:ok, build_report(reporting, date)}
        end
    end
  end

  defp current_reporting, do: Repo.one(from(r in Reporting))

  defp held_cash_by_property do
    from(g in Group,
      where: g.status == "active",
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(g.cash_paid_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp later_date(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  # ---------------------------------------------------------------------------
  # Report assembly
  # ---------------------------------------------------------------------------

  defp build_report(%Reporting{} = reporting, date) do
    events = Repo.all(from e in Event, where: e.posted_on <= ^date)

    {before, on_date} = Enum.split_with(events, &(Date.compare(&1.posted_on, date) == :lt))

    expiries = natural_expiries(reporting)

    expiry_before =
      expiries |> Enum.filter(&(Date.compare(elem(&1, 0), date) == :lt)) |> sum_expiries()

    expiry_on_date =
      expiries |> Enum.filter(&(Date.compare(elem(&1, 0), date) == :eq)) |> sum_expiries()

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_entries(reporting, before, on_date),
      "credit" => credit_object(reporting, before, on_date, expiry_before, expiry_on_date)
    }
  end

  defp sum_expiries(expiries),
    do: Enum.reduce(expiries, 0, fn {_date, amount}, sum -> sum + amount end)

  defp cash_entries(%Reporting{opening_cash_held_cents: opening_frozen}, before, on_date) do
    properties =
      Map.keys(opening_frozen)
      |> MapSet.new()
      |> MapSet.union(before |> Enum.map(& &1.property_id) |> MapSet.new())
      |> MapSet.union(on_date |> Enum.map(& &1.property_id) |> MapSet.new())

    movements = sum_by_class_and_property(on_date)

    properties
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn property_id ->
      opening =
        Map.get(opening_frozen, property_id, 0) +
          (before
           |> Enum.filter(&(&1.property_id == property_id))
           |> Enum.map(&held_delta/1)
           |> Enum.sum())

      day_movements =
        Map.new(@cash_classes, fn class ->
          {class <> "_cents", movements[{property_id, class}] || 0}
        end)

      day_net =
        on_date
        |> Enum.filter(&(&1.property_id == property_id))
        |> Enum.map(&held_delta/1)
        |> Enum.sum()

      closing = opening + day_net

      %{
        "property_id" => property_id,
        "opening_held_cents" => opening,
        "movements" => day_movements,
        "closing_held_cents" => closing
      }
    end)
    |> Enum.filter(&nonzero_entry?/1)
    |> Enum.sort_by(& &1["property_id"])
  end

  defp nonzero_entry?(%{"opening_held_cents" => opening, "closing_held_cents" => closing} = entry) do
    opening != 0 or closing != 0 or
      Enum.any?(entry["movements"], fn {_key, value} -> value != 0 end)
  end

  defp held_delta(%Event{classification: classification, amount_cents: amount}) do
    case classification do
      "received" -> amount
      "transferred_in" -> amount
      _ -> -amount
    end
  end

  defp sum_by_class_and_property(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      Map.update(
        acc,
        {event.property_id, event.classification},
        event.amount_cents,
        &(&1 + event.amount_cents)
      )
    end)
  end

  defp credit_object(
         %Reporting{opening_liability_cents: opening_frozen},
         before,
         on_date,
         expiry_before,
         expiry_on_date
       ) do
    totals_before = sum_by_class(before)
    totals_on_date = sum_by_class(on_date)

    net_before =
      liability_net(totals_before, expiry_before)

    movements =
      Map.new(@credit_classes, fn class ->
        amount =
          (totals_on_date[class] || 0) + if(class == "expired", do: expiry_on_date, else: 0)

        {class <> "_cents", amount}
      end)

    opening = opening_frozen + net_before

    closing = opening + liability_net(totals_on_date, expiry_on_date)

    %{
      "opening_liability_cents" => opening,
      "movements" => movements,
      "closing_liability_cents" => closing
    }
  end

  defp liability_net(totals, expiry_amount) do
    (totals["issued"] || 0) - (totals["expired"] || 0) - expiry_amount -
      (totals["consumed"] || 0) - (totals["revoked"] || 0) - (totals["absorbed"] || 0)
  end

  defp sum_by_class(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      Map.update(acc, event.classification, event.amount_cents, &(&1 + event.amount_cents))
    end)
  end

  # ---------------------------------------------------------------------------
  # Natural expiries
  # ---------------------------------------------------------------------------

  # Credit that remains unused through its `expires_on` date expires on the
  # following date. The amount is each lot's unfunded portion as of the end
  # of `expires_on`: the balance frozen at inception plus every recorded
  # per-lot movement posted no later than `expires_on`.
  defp natural_expiries(%Reporting{starts_on: starts_on, lot_snapshot: snapshot}) do
    by_lot =
      Repo.all(from l in LotEvent, order_by: l.id)
      |> Enum.group_by(& &1.credit_lot_id)

    snapshot_ids = Map.keys(snapshot) |> MapSet.new(&String.to_integer/1)
    event_ids = Map.keys(by_lot) |> MapSet.new()
    live_ids = event_ids |> MapSet.difference(snapshot_ids) |> MapSet.to_list()

    live_expires_on = live_expires_on_map(live_ids)

    snapshot_ids
    |> MapSet.union(event_ids)
    |> Enum.flat_map(fn lot_id ->
      case lot_origin(snapshot, live_expires_on, lot_id) do
        {base, expires_on} ->
          relevant =
            Enum.filter(by_lot[lot_id] || [], &(Date.compare(&1.posted_on, expires_on) != :gt))

          remaining =
            base.remaining_cents +
              Enum.sum(Enum.map(relevant, & &1.remaining_delta_cents))

          funded =
            base.funded_cents +
              Enum.sum(Enum.map(relevant, & &1.funded_delta_cents))

          amount = max(remaining - funded, 0)
          expires = Date.add(expires_on, 1)

          if amount > 0 and Date.compare(expires, starts_on) != :lt do
            [{expires, amount}]
          else
            []
          end

        nil ->
          []
      end
    end)
  end

  # Lots frozen at inception take their balance and expiry from the
  # snapshot; lots created later start at zero and take their expiry from
  # the live lot.
  defp lot_origin(snapshot, live_expires_on, lot_id) do
    case Map.fetch(snapshot, Integer.to_string(lot_id)) do
      {:ok, entry} ->
        {%{
           remaining_cents: entry["remaining_cents"],
           funded_cents: entry["funded_cents"]
         }, parse_snapshot_date(entry["expires_on"])}

      :error ->
        case Map.fetch(live_expires_on, lot_id) do
          {:ok, expires_on} -> {%{remaining_cents: 0, funded_cents: 0}, expires_on}
          :error -> nil
        end
    end
  end

  defp parse_snapshot_date(%Date{} = date), do: date
  defp parse_snapshot_date(iso) when is_binary(iso), do: Date.from_iso8601!(iso)

  defp live_expires_on_map([]), do: %{}

  defp live_expires_on_map(ids) do
    Repo.all(from l in CreditLot, where: l.id in ^ids, select: {l.id, l.expires_on})
    |> Map.new()
  end
end
