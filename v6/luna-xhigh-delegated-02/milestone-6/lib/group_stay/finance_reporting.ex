defmodule GroupStay.FinanceReporting do
  @moduledoc "The durable reporting inception point and opening position."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_commit_sequence, :integer
    field :opening_cash_json, :string
    field :opening_credit_lots_json, :string
    field :opening_liability_cents, :integer
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [
      :id,
      :starts_on,
      :start_commit_sequence,
      :opening_cash_json,
      :opening_credit_lots_json,
      :opening_liability_cents
    ])
    |> validate_required([
      :id,
      :starts_on,
      :opening_cash_json,
      :opening_credit_lots_json,
      :opening_liability_cents
    ])
    |> unique_constraint(:id)
  end
end
