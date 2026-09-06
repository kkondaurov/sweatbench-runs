defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report: how held cash and hotel-credit liability moved
  since finance reporting began.

  Reporting starts when the first `start_finance_reporting` operation is
  applied. The financial state immediately before that operation is processed
  becomes the opening position on its `starts_on` date — the held cash of each
  property and the credit liability — including every operation already
  committed, even one whose `occurred_on` is on or after `starts_on`.

  Every operation processed after that records its finance movements at the
  posting date, the later of its `occurred_on` and `starts_on`; later
  submissions can therefore change an earlier open report. Credit that
  remains unused expires on its `expires_on` date, and the report shows that
  expiry even when no partner operation was submitted that day. Reading
  reports never changes a report or any domain state.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Opening
  alias GroupStay.Finance.ReportingState
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @cash_classifications ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  ## Starting reporting

  @doc """
  Whether finance reporting has started.
  """
  def started? do
    Repo.exists?(ReportingState, id: 1)
  end

  @doc """
  The durable reporting inception point, or `:error` before reporting has
  started.
  """
  def started_state do
    case Repo.get(ReportingState, 1) do
      nil -> :error
      %ReportingState{} = state -> {:ok, state}
    end
  end

  @doc """
  Records the reporting inception point: the `starts_on` date and the opening
  position observed immediately before the start operation is processed.
  """
  def start_reporting(operation_id, starts_on) do
    openings =
      Repo.all(
        from g in Group,
          where: g.status == "active",
          group_by: g.property_id,
          select: {g.property_id, sum(g.deposit_paid_cents - g.credit_paid_cents)}
      )

    {:ok, state} =
      %ReportingState{}
      |> Ecto.Changeset.change(%{
        id: 1,
        starts_on: starts_on,
        operation_id: operation_id,
        opening_credit_liability_cents: opening_credit_liability_cents(starts_on)
      })
      |> Repo.insert()

    Enum.each(openings, fn {property_id, opening_held_cents} ->
      %Opening{}
      |> Ecto.Changeset.change(%{
        reporting_state_id: state.id,
        property_id: property_id,
        opening_held_cents: opening_held_cents || 0
      })
      |> Repo.insert!()
    end)

    :ok
  end

  # The credit liability as of the day before `starts_on`, observed from the
  # current state: credit applied to active groups plus unexpired lots. Lots
  # that had already expired before reporting began are pre-reporting history
  # and never enter the opening position.
  defp opening_credit_liability_cents(starts_on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^starts_on,
          select: sum(l.remaining_cents)
      )
      |> Kernel.||(0)

    applied_to_active_groups =
      Repo.one(
        from a in CreditApplication,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          select: sum(a.amount_cents)
      )
      |> Kernel.||(0)

    available + applied_to_active_groups
  end

  ## Recording movements

  @doc """
  The posting date of an operation processed on `occurred_on`: the later of
  its `occurred_on` and the reporting `starts_on`, or `nil` before reporting
  has started.
  """
  def posting_date(occurred_on) do
    case started_state() do
      {:ok, %ReportingState{starts_on: starts_on}} ->
        if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on

      :error ->
        nil
    end
  end

  @doc """
  Records finance movements for an operation processed on `occurred_on`, each
  a map with `property_id` (`nil` for company-wide credit movements),
  `classification`, and a signed `amount_cents`. A no-op before reporting has
  started; zero amounts are not recorded.
  """
  def record(occurred_on, movements) do
    case posting_date(occurred_on) do
      nil ->
        :ok

      posting_date ->
        Enum.each(movements, fn movement ->
          unless movement.amount_cents == 0 do
            %Movement{}
            |> Ecto.Changeset.change(%{
              posting_date: posting_date,
              property_id: movement.property_id,
              classification: movement.classification,
              amount_cents: movement.amount_cents
            })
            |> Repo.insert!()
          end
        end)
    end
  end

  ## Reading one day

  @doc """
  The daily finance report for `date`, or `{:error, :report_not_available}`
  before reporting has started or for a date before `starts_on`.
  """
  def daily_report(%Date{} = date) do
    case started_state() do
      {:ok, %ReportingState{} = state} ->
        if Date.compare(date, state.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(state, date)}
        end

      :error ->
        {:error, :report_not_available}
    end
  end

  defp build_report(state, date) do
    amounts = movement_amounts(date)
    openings = opening_amounts(state)

    expired_cents =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^state.starts_on and l.expires_on <= ^date,
          select: sum(l.remaining_cents + l.clawed_back_expired_cents)
      )
      |> Kernel.||(0)

    property_ids =
      (Map.keys(openings) ++
         for(
           {{property_id, _classification}, _amount} <- amounts,
           not is_nil(property_id),
           do: property_id
         ))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => Enum.flat_map(property_ids, &cash_entry(&1, openings, amounts)),
      "credit" => credit_entry(state, amounts, expired_cents)
    }
  end

  # Net movement amounts through `date`, keyed by property (nil for credit)
  # and classification.
  defp movement_amounts(date) do
    Repo.all(
      from m in Movement,
        where: m.posting_date <= ^date,
        group_by: [m.property_id, m.classification],
        select: {m.property_id, m.classification, sum(m.amount_cents)}
    )
    |> Map.new(fn {property_id, classification, amount_cents} ->
      {{property_id, classification}, amount_cents}
    end)
  end

  defp opening_amounts(%ReportingState{} = state) do
    Repo.all(from o in Opening, where: o.reporting_state_id == ^state.id)
    |> Map.new(&{&1.property_id, &1.opening_held_cents})
  end

  # A property is omitted only when its opening balance, closing balance, and
  # every movement are zero.
  defp cash_entry(property_id, openings, amounts) do
    opening_held_cents = Map.get(openings, property_id, 0)

    movements =
      Map.new(@cash_classifications, fn classification ->
        {classification, Map.get(amounts, {property_id, classification}, 0)}
      end)

    if opening_held_cents == 0 and Enum.all?(movements, fn {_k, v} -> v == 0 end) do
      []
    else
      closing_held_cents =
        opening_held_cents + movements["received"] + movements["transferred_in"] -
          movements["transferred_out"] - movements["refunded"] - movements["retained"] -
          movements["converted_to_credit"] - movements["reduced"] -
          movements["charged_back"]

      [
        %{
          "property_id" => property_id,
          "opening_held_cents" => opening_held_cents,
          "movements" =>
            Map.new(movements, fn {classification, amount_cents} ->
              {classification <> "_cents", amount_cents}
            end),
          "closing_held_cents" => closing_held_cents
        }
      ]
    end
  end

  defp credit_entry(%ReportingState{} = state, amounts, expired_cents) do
    issued = Map.get(amounts, {nil, "issued"}, 0)
    # Unused credit expires on its expires_on date; restored credit whose
    # expiry has already passed expires immediately at its posting date.
    expired = Map.get(amounts, {nil, "expired"}, 0) + expired_cents
    consumed = Map.get(amounts, {nil, "consumed"}, 0)
    revoked = Map.get(amounts, {nil, "revoked"}, 0)
    absorbed = Map.get(amounts, {nil, "absorbed"}, 0)

    opening_liability_cents = state.opening_credit_liability_cents

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => %{
        "issued_cents" => issued,
        "expired_cents" => expired,
        "consumed_cents" => consumed,
        "revoked_cents" => revoked,
        "absorbed_cents" => absorbed
      },
      "closing_liability_cents" =>
        opening_liability_cents + issued - expired - consumed - revoked - absorbed
    }
  end
end
