defmodule GroupStay.Ledger.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash_by_property, :map
    field :opening_credit_cents, :integer
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:id, :starts_on, :opening_cash_by_property, :opening_credit_cents])
    |> validate_required([:id, :starts_on, :opening_cash_by_property, :opening_credit_cents])
  end
end

defmodule GroupStay.Ledger.FinanceCreditOpening do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_openings" do
    field :credit_lot_id, :integer
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on, :date
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :available_cents, :applied_cents, :expires_on])
    |> validate_required([:credit_lot_id, :available_cents, :applied_cents, :expires_on])
    |> unique_constraint(:credit_lot_id)
  end
end

defmodule GroupStay.Ledger.FinanceCashMovement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_movements" do
    field :posting_on, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:posting_on, :property_id, :classification, :amount_cents, :late_adjustment])
    |> validate_required([:posting_on, :property_id, :classification, :amount_cents])
  end
end

defmodule GroupStay.Ledger.FinanceCreditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_events" do
    field :posting_on, :date
    field :credit_lot_id, :integer
    field :kind, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:posting_on, :credit_lot_id, :kind, :amount_cents, :late_adjustment])
    |> validate_required([:posting_on, :credit_lot_id, :kind, :amount_cents])
  end
end

defmodule GroupStay.Ledger.FinancePeriodClose do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end

defmodule GroupStay.Ledger.FinanceDailyReportSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_daily_report_snapshots" do
    field :date, :date
    field :data, :map
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:date, :data])
    |> validate_required([:date, :data])
    |> unique_constraint(:date)
  end
end

defmodule GroupStay.Ledger.CashPaymentSettlement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "cash_payment_settlements" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
  end

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, [
      :payment_operation_id,
      :group_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_required([:payment_operation_id, :group_id])
    |> unique_constraint([:payment_operation_id, :group_id])
  end
end
