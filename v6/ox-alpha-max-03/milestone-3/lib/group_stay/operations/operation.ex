defmodule GroupStay.Operations.Operation do
  @moduledoc false

  defstruct [
    :operation_id,
    :type,
    :occurred_on,
    :group_id,
    :expected_revision,
    :guest_id,
    :property_id,
    :arrival_on,
    :departure_on,
    :rate_plan,
    :rooms,
    :amount_cents,
    :new_arrival_on,
    :refund_method
  ]
end
