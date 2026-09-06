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
    :room_ids,
    :amount_cents,
    :new_arrival_on,
    :refund_method,
    :payment_operation_id,
    :source_group_id,
    :destination_group_id,
    :destination_expected_revision
  ]
end
