defmodule GroupStay.OperationalCore.CreditLotAccount do
  use Ecto.Schema

  @primary_key {:source_operation_id, :string, autogenerate: false}
  schema "credit_lot_accounts" do
  end
end
