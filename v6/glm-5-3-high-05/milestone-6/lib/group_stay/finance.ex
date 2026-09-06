defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting: the durable reporting inception point and the
  daily report that explains how held cash and hotel-credit liability moved.

  Reporting starts with the first applied `start_finance_reporting`
  operation. The opening position on `starts_on` is the financial state
  immediately before that operation processed, including every operation
  already committed even when its `occurred_on` is on or after `starts_on`;
  operations earlier in the same batch therefore contribute to the opening
  position and later ones contribute movements.

  Every finance effect of an operation processed after reporting started is
  posted exactly once, as a signed `GroupStay.Finance.Event` on the
  operation's reporting posting date: the later of its `occurred_on` and
  `starts_on`. Rejected operations leave no movement (their writes are
  undone with the operation's savepoint) and a durable retry replays its
  stored result without re-posting, so later submissions can change an
  earlier open report but no movement is ever reported twice.

  The per-property opening held-cash position is derived, not stored:
  current held cash per property minus every posted cash movement equals
  the opening position, because each operation posts all of its cash
  effects. Hotel-credit liability cannot be derived that way (lot expiry is
  evaluated against a reference date rather than recorded), so the opening
  liability is snapshotted when reporting starts. Credit that remains
  unused through its lot's `expires_on` date expires on the following date
  and is shown as an expiry movement on that date even when no partner
  operation was submitted that day.
  """

  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Event
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups.Allocation
  alias GroupStay.Repo

  import Ecto.Query

  @cash_movement_kinds ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  @credit_movement_kinds ~w(
    credit_issued
    credit_expired
    credit_consumed
    credit_revoked
    credit_absorbed
  )

  # A movement's sign in the held-cash identity:
  #
  #     closing held = opening held
  #                  + received + transferred in - transferred out
  #                  - refunded - retained - converted to credit
  #                  - reduced - charged back
  @cash_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  @cash_movement_keys %{
    "received" => "received_cents",
    "transferred_in" => "transferred_in_cents",
    "transferred_out" => "transferred_out_cents",
    "refunded" => "refunded_cents",
    "retained" => "retained_cents",
    "converted_to_credit" => "converted_to_credit_cents",
    "reduced" => "reduced_cents",
    "charged_back" => "charged_back_cents"
  }

  ## Reporting state

  @doc "`true` once an applied `start_finance_reporting` operation has been processed."
  def started?, do: Reporting.one() != nil

  @doc """
  Starts finance reporting on `starts_on`, recording the opening credit
  liability as of that date from the currently committed state. Only the
  first applied start operation may call this.
  """
  def start_reporting!(starts_on) do
    %Reporting{id: 1}
    |> Reporting.changeset(%{
      starts_on: starts_on,
      opening_liability_cents: Credit.liability_cents(starts_on)
    })
    |> Repo.insert!()
  end

  ## Posting movements

  @doc """
  Posts a signed cash movement for `property_id`. A no-op when reporting
  has not started or the amount is zero.
  """
  def record_cash!(property_id, kind, amount_cents, occurred_on)
      when kind in @cash_movement_kinds and is_integer(amount_cents) do
    post_event!(property_id, kind, amount_cents, occurred_on)
  end

  @doc """
  Posts a signed company-wide credit movement. A no-op when reporting has
  not started or the amount is zero.
  """
  def record_credit!(kind, amount_cents, occurred_on)
      when kind in @credit_movement_kinds and is_integer(amount_cents) do
    post_event!(nil, kind, amount_cents, occurred_on)
  end

  @doc """
  Posts revocation movements for entitlement removals (`{lot, removed}`).
  A revocation removes liability only while the lot is still unexpired on
  the posting date; an expired lot's available credit already left the
  liability through expiry, so removing it is not a new movement.
  """
  def record_revoked!(removals, occurred_on) do
    case posting_on(occurred_on) do
      nil ->
        :ok

      posting_on ->
        for {%Lot{} = lot, removed} <- removals,
            removed > 0 and Date.compare(lot.expires_on, posting_on) != :lt,
            do: post_event!(nil, "credit_revoked", removed, occurred_on)

        :ok
    end
  end

  defp post_event!(_property_id, _kind, 0, _occurred_on), do: :ok

  defp post_event!(property_id, kind, amount_cents, occurred_on) do
    case posting_on(occurred_on) do
      nil ->
        :ok

      posting_on ->
        %Event{}
        |> Event.changeset(%{
          posting_on: posting_on,
          property_id: property_id,
          kind: kind,
          amount_cents: amount_cents
        })
        |> Repo.insert!()

        :ok
    end
  end

  # The reporting posting date: the later of `occurred_on` and `starts_on`.
  # `nil` while reporting has not started.
  defp posting_on(occurred_on) do
    case Reporting.one() do
      nil ->
        nil

      %Reporting{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on
    end
  end

  ## Reading one day

  @doc """
  The daily finance report for `date`:

      {:ok, report} | {:error, :not_started} | {:error, :before_start}

  Reading a report never changes a report or any domain state.
  """
  def daily_report(%Date{} = date) do
    case Reporting.one() do
      nil ->
        {:error, :not_started}

      %Reporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :before_start}
        else
          {:ok, build_report(reporting, date)}
        end
    end
  end

  defp build_report(%Reporting{} = reporting, date) do
    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_section(reporting, date),
      "credit" => credit_section(reporting, date)
    }
  end

  ## Cash

  # Each day's per-property cash entry. The day's opening held cash derives
  # from the current held cash (which the posting journal reconciles to the
  # reporting-period opening) minus every movement posting on or after the
  # day, so day openings telescope from the period opening to today.
  defp cash_section(%Reporting{} = _reporting, date) do
    events = cash_events()
    held = held_cash_by_property()

    events_by_property = Enum.group_by(events, & &1.property_id)

    properties =
      (Map.keys(held) ++ Map.keys(events_by_property))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(fn property_id ->
      property_events = Map.get(events_by_property, property_id, [])

      # Held cash at the start of the day: current held cash minus every
      # movement posting on or after the day.
      posted_on_or_after =
        property_events
        |> Enum.filter(&(Date.compare(&1.posting_on, date) != :lt))
        |> Enum.sum_by(fn event -> @cash_signs[event.kind] * event.amount_cents end)

      opening = Map.get(held, property_id, 0) - posted_on_or_after

      movements =
        Map.new(@cash_movement_keys, fn {kind, key} ->
          total =
            property_events
            |> Enum.filter(&(&1.kind == kind and &1.posting_on == date))
            |> Enum.sum_by(& &1.amount_cents)

          {key, total}
        end)

      closing =
        opening +
          Enum.sum_by(@cash_movement_keys, fn {kind, key} ->
            @cash_signs[kind] * movements[key]
          end)

      %{
        "property_id" => property_id,
        "opening_held_cents" => opening,
        "movements" => movements,
        "closing_held_cents" => closing
      }
    end)
    |> Enum.reject(&all_zero_cash?/1)
  end

  defp all_zero_cash?(entry) do
    entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
      Enum.all?(entry["movements"], fn {_key, amount} -> amount == 0 end)
  end

  defp cash_events do
    from(e in Event, where: e.kind in ^@cash_movement_kinds)
    |> Repo.all()
  end

  defp held_cash_by_property do
    from(a in Allocation,
      join: g in assoc(a, :group),
      where: a.kind == "cash" and a.remaining_cents > 0,
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(a.remaining_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## Credit

  defp credit_section(%Reporting{} = reporting, date) do
    events =
      from(e in Event, where: e.kind in ^@credit_movement_kinds)
      |> Repo.all()

    movements = %{
      "issued_cents" => posted_at(events, "credit_issued", date),
      "expired_cents" =>
        posted_at(events, "credit_expired", date) + natural_expiry_cents(reporting, date),
      "consumed_cents" => posted_at(events, "credit_consumed", date),
      "revoked_cents" => posted_at(events, "credit_revoked", date),
      "absorbed_cents" => posted_at(events, "credit_absorbed", date)
    }

    net_on_date =
      movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
        movements["revoked_cents"] - movements["absorbed_cents"]

    # Liability at the start of the day: the reporting-period opening plus
    # every movement through the previous day.
    opening =
      reporting.opening_liability_cents +
        net_through(events, reporting, Date.add(date, -1))

    %{
      "opening_liability_cents" => opening,
      "movements" => movements,
      "closing_liability_cents" => opening + net_on_date
    }
  end

  # Every posted movement and natural expiry on or before `date`.
  defp net_through(events, %Reporting{} = reporting, date) do
    posted_net =
      events
      |> Enum.filter(&(Date.compare(&1.posting_on, date) != :gt))
      |> Enum.sum_by(&credit_delta/1)

    posted_net + natural_expiry_through(reporting, date)
  end

  defp posted_at(events, kind, date) do
    events
    |> Enum.filter(&(&1.kind == kind and &1.posting_on == date))
    |> Enum.sum_by(& &1.amount_cents)
  end

  defp credit_delta(%Event{} = event) do
    case event.kind do
      "credit_issued" -> event.amount_cents
      _ -> -event.amount_cents
    end
  end

  # Credit that remains unused through its lot's `expires_on` date expires
  # on the following date. The expiring amount is the lot's current
  # remaining balance: lots are only consumed while unexpired, so a lot's
  # remaining balance is exactly what was still unused through its expiry.
  # Only lots available on `starts_on` (expiry date after `starts_on`)
  # expire within reporting; a lot already expired at the start is absent
  # from the opening liability and produces no movement.
  defp natural_expiry_cents(%Reporting{} = reporting, date) do
    natural_expiry_through(reporting, date) -
      natural_expiry_through(reporting, Date.add(date, -1))
  end

  defp natural_expiry_through(%Reporting{} = reporting, date) do
    from(l in Lot,
      where:
        l.expires_on >= ^reporting.starts_on and l.expires_on < ^date and
          l.remaining_cents > 0,
      select: coalesce(sum(l.remaining_cents), 0)
    )
    |> Repo.one()
  end
end
