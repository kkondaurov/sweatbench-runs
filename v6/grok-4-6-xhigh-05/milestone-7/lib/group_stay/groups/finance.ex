defmodule GroupStay.Groups.Finance do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.FundingAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.PaymentState
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @ctx {__MODULE__, :ctx}
  @singleton_id 1

  @cash_classifications [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]

  @credit_classifications ["issued", "expired", "consumed", "revoked", "absorbed"]

  defmodule Reporting do
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}

    schema "finance_reporting" do
      field :start_operation_id, :string
      field :starts_on, :date
      field :opening_liability_cents, :integer, default: 0
      field :closed_through, :date
    end
  end

  defmodule OpeningCash do
    use Ecto.Schema

    schema "finance_opening_cash" do
      field :property_id, :string
      field :opening_held_cents, :integer, default: 0
    end
  end

  defmodule CashMovement do
    use Ecto.Schema

    schema "finance_cash_movements" do
      field :posted_on, :date
      field :property_id, :string
      field :classification, :string
      field :amount_cents, :integer
      field :operation_id, :string
      field :late_adjustment, :boolean, default: false
    end
  end

  defmodule CreditMovement do
    use Ecto.Schema

    schema "finance_credit_movements" do
      field :posted_on, :date
      field :classification, :string
      field :amount_cents, :integer
      field :operation_id, :string
      field :late_adjustment, :boolean, default: false
    end
  end

  defmodule TrackedLot do
    use Ecto.Schema

    schema "finance_lots" do
      field :lot_id, :binary_id
      field :expires_on, :date
      field :opening_available_cents, :integer, default: 0
    end
  end

  defmodule LotDelta do
    use Ecto.Schema

    schema "finance_lot_deltas" do
      field :lot_id, :binary_id
      field :posted_on, :date
      field :occurred_on, :date
      field :delta_cents, :integer
      field :operation_id, :string
    end
  end

  defmodule ClosedReport do
    use Ecto.Schema

    schema "finance_closed_reports" do
      field :report_date, :date
      field :data, :map
    end
  end

  defmodule Bucket do
    use Ecto.Schema

    schema "payment_property_buckets" do
      field :payment_operation_id, :string
      field :property_id, :string
      field :held_cents, :integer, default: 0
      field :refunded_cents, :integer, default: 0
      field :retained_cents, :integer, default: 0
      field :converted_to_credit_cents, :integer, default: 0
      field :reduced_cents, :integer, default: 0
      field :charged_back_cents, :integer, default: 0
    end
  end

  def put_context(operation) when is_map(operation) do
    Process.put(@ctx, %{
      operation_id: operation["operation_id"] || operation[:operation_id],
      occurred_on: parse_date(operation["occurred_on"] || operation[:occurred_on])
    })
  end

  def put_context(_), do: :ok

  def clear_context, do: Process.delete(@ctx)

  def inception do
    Repo.get(Reporting, @singleton_id)
  end

  def started?, do: not is_nil(inception())

  def as_of_date, do: context_occurred_on() || Date.utc_today()

  def start(starts_on, operation_id) do
    case inception() do
      %Reporting{} ->
        {:error, :reporting_already_started}

      nil ->
        case insert_inception(starts_on, operation_id) do
          {:ok, reporting} ->
            snapshot!(reporting)
            :ok

          {:error, _changeset} ->
            {:error, :reporting_already_started}
        end
    end
  end

  def close(%Date{} = period_end_on) do
    case inception() do
      nil ->
        {:error, :invalid_period}

      %Reporting{} = reporting ->
        cond do
          Date.compare(period_end_on, reporting.starts_on) == :lt ->
            {:error, :invalid_period}

          closed_through?(reporting) and
              Date.compare(period_end_on, reporting.closed_through) != :gt ->
            {:error, :invalid_period}

          true ->
            snapshot_closed_reports!(reporting, period_end_on)

            reporting
            |> change(%{closed_through: period_end_on})
            |> Repo.update!()

            :ok
        end
    end
  end

  def daily_report(%Date{} = date) do
    case inception() do
      nil ->
        {:error, :report_not_available}

      %Reporting{starts_on: starts_on} = reporting ->
        if Date.compare(date, starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, load_or_build_report(reporting, date)}
        end
    end
  end

  def movement(property_id, classification, amount_cents)
      when is_binary(property_id) and is_integer(amount_cents) and amount_cents != 0 do
    classification = classification_name(classification)

    if reporting_active?() and classification in @cash_classifications do
      {posted_on, late_adjustment} = posting()

      Repo.insert!(%CashMovement{
        posted_on: posted_on,
        property_id: property_id,
        classification: classification,
        amount_cents: amount_cents,
        operation_id: context_operation_id(),
        late_adjustment: late_adjustment
      })
    end

    :ok
  end

  def movement(_property_id, _classification, _amount_cents), do: :ok

  def issued(amount_cents), do: credit_movement("issued", amount_cents)
  def expired(amount_cents), do: credit_movement("expired", amount_cents)
  def consumed(amount_cents), do: credit_movement("consumed", amount_cents)
  def revoked(amount_cents), do: credit_movement("revoked", amount_cents)
  def absorbed(amount_cents), do: credit_movement("absorbed", amount_cents)

  def ensure_lot(%CreditLot{} = lot, opening_available \\ 0) do
    if reporting_active?() do
      unless Repo.exists?(from t in TrackedLot, where: t.lot_id == ^lot.id) do
        Repo.insert!(%TrackedLot{
          lot_id: lot.id,
          expires_on: lot.expires_on,
          opening_available_cents: opening_available
        })
      end
    end

    :ok
  end

  def note_available(%CreditLot{} = lot, delta_cents)
      when is_integer(delta_cents) and delta_cents != 0 do
    if reporting_active?() do
      ensure_lot(lot)

      {posted_on, _late_adjustment} = posting()

      Repo.insert!(%LotDelta{
        lot_id: lot.id,
        posted_on: posted_on,
        occurred_on: context_occurred_on(),
        delta_cents: delta_cents,
        operation_id: context_operation_id()
      })
    end

    :ok
  end

  def note_available(_lot, _delta_cents), do: :ok

  def bucket(payment_id, property_id, deltas)
      when is_binary(payment_id) and is_binary(property_id) and is_map(deltas) do
    deltas = Enum.reject(deltas, fn {_k, v} -> v == 0 end)

    if deltas == [] do
      :ok
    else
      bucket =
        case Repo.get_by(Bucket, payment_operation_id: payment_id, property_id: property_id) do
          nil ->
            Repo.insert!(%Bucket{
              payment_operation_id: payment_id,
              property_id: property_id
            })

          existing ->
            existing
        end

      changes =
        Enum.reduce(deltas, %{}, fn {field, amount}, acc ->
          Map.put(acc, field, Map.get(bucket, field) + amount)
        end)

      bucket
      |> change(changes)
      |> Repo.update!()

      :ok
    end
  end

  def bucket(_payment_id, _property_id, _deltas), do: :ok

  def list_buckets(payment_id) when is_binary(payment_id) do
    from(b in Bucket, where: b.payment_operation_id == ^payment_id)
    |> Repo.all()
  end

  def list_buckets(_), do: []

  def ensure_payment_buckets(nil), do: :ok

  def ensure_payment_buckets(payment_id) when is_binary(payment_id) do
    case Repo.get(PaymentState, payment_id) do
      nil -> :ok
      payment -> ensure_buckets(payment)
    end
  end

  def ensure_payment_buckets(_), do: :ok

  def ensure_buckets(%PaymentState{} = payment) do
    if Repo.exists?(
         from b in Bucket, where: b.payment_operation_id == ^payment.payment_operation_id
       ) do
      :ok
    else
      reconstruct_buckets(payment)
    end
  end

  defp insert_inception(starts_on, operation_id) do
    %Reporting{}
    |> change(%{
      id: @singleton_id,
      start_operation_id: operation_id,
      starts_on: starts_on,
      opening_liability_cents: 0
    })
    |> Repo.insert()
  end

  defp snapshot!(%Reporting{} = reporting) do
    today = Date.utc_today()

    opening_cash =
      from(g in Group,
        where: g.status == "active",
        group_by: g.property_id,
        select: {g.property_id, coalesce(sum(g.cash_paid_cents), 0)}
      )
      |> Repo.all()

    Enum.each(opening_cash, fn {property_id, amount} ->
      if amount != 0 do
        Repo.insert!(%OpeningCash{property_id: property_id, opening_held_cents: amount})
      end
    end)

    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^today,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    applied =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.credit_paid_cents), 0)
      ) || 0

    reporting
    |> change(%{opening_liability_cents: available + applied})
    |> Repo.update!()

    from(l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^today)
    |> Repo.all()
    |> Enum.each(fn lot ->
      Repo.insert!(%TrackedLot{
        lot_id: lot.id,
        expires_on: lot.expires_on,
        opening_available_cents: lot.remaining_cents
      })
    end)

    from(p in PaymentState)
    |> Repo.all()
    |> Enum.each(&ensure_buckets/1)

    :ok
  end

  defp reconstruct_buckets(%PaymentState{} = payment) do
    held_rows =
      from(a in FundingAllocation,
        join: r in Room,
        on: r.group_id == a.group_id and r.room_id == a.room_id,
        join: g in Group,
        on: g.group_id == a.group_id,
        where:
          a.source_operation_id == ^payment.payment_operation_id and a.fund_type == "cash" and
            r.status != "cancelled",
        group_by: g.property_id,
        select: {g.property_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()

    original_property =
      case Repo.get(Group, payment.group_id) do
        %Group{property_id: property_id} -> property_id
        _ -> nil
      end

    held_map = Map.new(held_rows)

    properties =
      held_map
      |> Map.keys()
      |> maybe_add_property(original_property)

    Enum.each(properties, fn property_id ->
      held = Map.get(held_map, property_id, 0)

      settled? = original_property == property_id

      Repo.insert!(%Bucket{
        payment_operation_id: payment.payment_operation_id,
        property_id: property_id,
        held_cents: held,
        refunded_cents: if(settled?, do: payment.refunded_cents, else: 0),
        retained_cents: if(settled?, do: payment.retained_cents, else: 0),
        converted_to_credit_cents: if(settled?, do: payment.converted_to_credit_cents, else: 0),
        reduced_cents: if(settled?, do: payment.reduced_cents, else: 0),
        charged_back_cents: if(settled?, do: payment.charged_back_cents, else: 0)
      })
    end)

    if properties == [] and original_property do
      Repo.insert!(%Bucket{
        payment_operation_id: payment.payment_operation_id,
        property_id: original_property,
        held_cents: payment.held_cents,
        refunded_cents: payment.refunded_cents,
        retained_cents: payment.retained_cents,
        converted_to_credit_cents: payment.converted_to_credit_cents,
        reduced_cents: payment.reduced_cents,
        charged_back_cents: payment.charged_back_cents
      })
    end

    :ok
  end

  defp maybe_add_property(properties, nil), do: properties

  defp maybe_add_property(properties, property_id) do
    if property_id in properties, do: properties, else: [property_id | properties]
  end

  defp credit_movement(classification, amount_cents)
       when is_integer(amount_cents) and amount_cents != 0 do
    if reporting_active?() and classification in @credit_classifications do
      {posted_on, late_adjustment} = posting()

      Repo.insert!(%CreditMovement{
        posted_on: posted_on,
        classification: classification,
        amount_cents: amount_cents,
        operation_id: context_operation_id(),
        late_adjustment: late_adjustment
      })
    end

    :ok
  end

  defp credit_movement(_classification, _amount_cents), do: :ok

  defp reporting_active? do
    started?() and not is_nil(Process.get(@ctx))
  end

  defp posting do
    reporting = inception()
    starts_on = reporting.starts_on
    first_open = first_open_on(reporting)

    natural =
      case context_occurred_on() do
        %Date{} = occurred_on -> later(occurred_on, starts_on)
        _ -> starts_on
      end

    posted_on = later(natural, first_open)
    {posted_on, Date.compare(posted_on, natural) == :gt}
  end

  defp first_open_on(%Reporting{closed_through: nil, starts_on: starts_on}), do: starts_on
  defp first_open_on(%Reporting{closed_through: cutoff}), do: Date.add(cutoff, 1)

  defp closed_through?(%Reporting{closed_through: %Date{}}), do: true
  defp closed_through?(%Reporting{}), do: false

  defp load_or_build_report(reporting, date) do
    case Repo.get_by(ClosedReport, report_date: date) do
      %ClosedReport{data: data} -> data
      nil -> build_report(reporting, date)
    end
  end

  defp snapshot_closed_reports!(reporting, period_end_on) do
    start_on =
      case reporting.closed_through do
        nil -> reporting.starts_on
        cutoff -> Date.add(cutoff, 1)
      end

    Enum.each(Date.range(start_on, period_end_on), fn date ->
      report = freeze_report(build_report(reporting, date, "closed"))
      Repo.insert!(%ClosedReport{report_date: date, data: report})
    end)
  end

  defp freeze_report(report) do
    report |> Jason.encode!() |> Jason.decode!()
  end

  defp context_occurred_on do
    case Process.get(@ctx) do
      %{occurred_on: occurred_on} -> occurred_on
      _ -> nil
    end
  end

  defp context_operation_id do
    case Process.get(@ctx) do
      %{operation_id: operation_id} -> operation_id
      _ -> nil
    end
  end

  defp later(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp classification_name(value) when is_atom(value), do: Atom.to_string(value)
  defp classification_name(value) when is_binary(value), do: value

  defp build_report(%Reporting{} = reporting, %Date{} = date, status \\ nil) do
    {cash, late_cash} = cash_report(reporting, date)
    {credit, late_credit} = credit_report(reporting, date)

    %{
      date: Date.to_iso8601(date),
      status: status || report_status(reporting, date),
      cash: cash,
      credit: credit,
      late_adjustments: %{
        cash: late_cash,
        credit: late_credit
      }
    }
  end

  defp report_status(%Reporting{closed_through: nil}, _date), do: "open"

  defp report_status(%Reporting{closed_through: cutoff}, date) do
    if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
  end

  defp cash_report(%Reporting{}, date) do
    opening_by_property =
      from(o in OpeningCash)
      |> Repo.all()
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    movements =
      from(m in CashMovement, where: m.posted_on <= ^date)
      |> Repo.all()

    properties =
      opening_by_property
      |> Map.keys()
      |> Kernel.++(Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(properties, fn property_id ->
        opening_snapshot = Map.get(opening_by_property, property_id, 0)

        property_movements = Enum.filter(movements, &(&1.property_id == property_id))
        before = Enum.filter(property_movements, &(Date.compare(&1.posted_on, date) == :lt))
        on_date = Enum.filter(property_movements, &(Date.compare(&1.posted_on, date) == :eq))
        ordinary = Enum.reject(on_date, &late_adjustment?/1)
        late_rows = Enum.filter(on_date, &late_adjustment?/1)

        opening = opening_snapshot + net_cash(before)
        day = cash_movement_map(ordinary)
        late_day = cash_movement_map(late_rows)
        closing = closing_held(opening, add_movement_maps(day, late_day))

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: day,
          closing_held_cents: closing,
          late_movements: late_day
        }
      end)

    cash =
      entries
      |> Enum.reject(&zero_cash?/1)
      |> Enum.map(&Map.delete(&1, :late_movements))

    late_cash =
      entries
      |> Enum.reject(&zero_movements?(&1.late_movements))
      |> Enum.map(fn entry ->
        %{property_id: entry.property_id, movements: entry.late_movements}
      end)

    {cash, late_cash}
  end

  defp cash_movement_map(rows) do
    Enum.reduce(rows, empty_cash_movements(), fn row, acc ->
      key = :"#{row.classification}_cents"
      Map.update(acc, key, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  defp empty_cash_movements do
    %{
      received_cents: 0,
      transferred_in_cents: 0,
      transferred_out_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }
  end

  defp net_cash(rows) do
    movements = cash_movement_map(rows)
    closing_held(0, movements)
  end

  defp closing_held(opening, movements) do
    opening + movements.received_cents + movements.transferred_in_cents -
      movements.transferred_out_cents - movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents -
      movements.charged_back_cents
  end

  defp zero_cash?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      zero_movements?(entry.movements) and zero_movements?(entry.late_movements)
  end

  defp zero_movements?(movements) do
    Enum.all?(movements, fn {_k, v} -> v == 0 end)
  end

  defp late_adjustment?(row), do: row.late_adjustment == true

  defp add_movement_maps(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp credit_report(%Reporting{} = reporting, date) do
    starts_on = reporting.starts_on

    movements =
      from(m in CreditMovement, where: m.posted_on <= ^date)
      |> Repo.all()

    lots = Repo.all(TrackedLot)
    deltas = Repo.all(LotDelta)

    before_ops = Enum.filter(movements, &(Date.compare(&1.posted_on, date) == :lt))
    on_date_ops = Enum.filter(movements, &(Date.compare(&1.posted_on, date) == :eq))
    ordinary_ops = Enum.reject(on_date_ops, &late_adjustment?/1)
    late_ops = Enum.filter(on_date_ops, &late_adjustment?/1)

    expired_before = calendar_expiry_before(date, lots, deltas, starts_on)
    {expired_ordinary, expired_late} = calendar_expiry_on(date, lots, deltas, starts_on)

    opening =
      reporting.opening_liability_cents + net_credit(before_ops) - expired_before

    day = credit_movement_map(ordinary_ops)
    day = Map.update!(day, :expired_cents, &(&1 + expired_ordinary))

    late_day = credit_movement_map(late_ops)
    late_day = Map.update!(late_day, :expired_cents, &(&1 + expired_late))

    combined = add_movement_maps(day, late_day)

    closing =
      opening + combined.issued_cents - combined.expired_cents - combined.consumed_cents -
        combined.revoked_cents - combined.absorbed_cents

    credit = %{
      opening_liability_cents: opening,
      movements: day,
      closing_liability_cents: closing
    }

    {credit, late_day}
  end

  defp credit_movement_map(rows) do
    Enum.reduce(rows, empty_credit_movements(), fn row, acc ->
      key = :"#{row.classification}_cents"
      Map.update(acc, key, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  defp empty_credit_movements do
    %{
      issued_cents: 0,
      expired_cents: 0,
      consumed_cents: 0,
      revoked_cents: 0,
      absorbed_cents: 0
    }
  end

  defp net_credit(rows) do
    m = credit_movement_map(rows)
    m.issued_cents - m.expired_cents - m.consumed_cents - m.revoked_cents - m.absorbed_cents
  end

  defp calendar_expiry_on(date, lots, deltas, starts_on) do
    Enum.reduce(lots, {0, 0}, fn lot, {ordinary, late} ->
      natural = later(Date.add(lot.expires_on, 1), starts_on)

      ordinary =
        if Date.compare(natural, date) == :eq do
          ordinary + max(available_for_expiry(lot, deltas, natural), 0)
        else
          ordinary
        end

      late =
        if Date.compare(date, natural) == :gt do
          late + deferred_expiry_on(lot, deltas, date)
        else
          late
        end

      {ordinary, late}
    end)
  end

  defp calendar_expiry_before(date, lots, deltas, starts_on) do
    Enum.reduce(lots, 0, fn lot, acc ->
      natural = later(Date.add(lot.expires_on, 1), starts_on)

      natural_amount =
        if Date.compare(natural, date) == :lt do
          max(available_for_expiry(lot, deltas, natural), 0)
        else
          0
        end

      acc + natural_amount + deferred_expiry_before(lot, deltas, natural, date)
    end)
  end

  defp deferred_expiry_on(lot, deltas, date) do
    net =
      Enum.reduce(deltas, 0, fn delta, acc ->
        if delta.lot_id == lot.lot_id and Date.compare(delta.posted_on, date) == :eq do
          acc + delta.delta_cents
        else
          acc
        end
      end)

    max(net, 0)
  end

  defp deferred_expiry_before(lot, deltas, natural, date) do
    deltas
    |> Enum.filter(&(&1.lot_id == lot.lot_id))
    |> Enum.group_by(& &1.posted_on)
    |> Enum.reduce(0, fn {posted_on, day_deltas}, acc ->
      if Date.compare(posted_on, natural) == :gt and Date.compare(posted_on, date) == :lt do
        net = Enum.reduce(day_deltas, 0, fn delta, sum -> sum + delta.delta_cents end)
        acc + max(net, 0)
      else
        acc
      end
    end)
  end

  defp available_for_expiry(lot, deltas, expiry_on) do
    lot.opening_available_cents +
      Enum.reduce(deltas, 0, fn delta, acc ->
        if delta.lot_id == lot.lot_id and delta_before_expiry?(delta, lot, expiry_on) do
          acc + delta.delta_cents
        else
          acc
        end
      end)
  end

  defp delta_before_expiry?(delta, lot, expiry_on) do
    case Date.compare(delta.posted_on, expiry_on) do
      :lt ->
        true

      :eq ->
        case delta.occurred_on do
          nil -> true
          occurred_on -> Date.compare(occurred_on, lot.expires_on) != :gt
        end

      :gt ->
        false
    end
  end
end
