defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  test "returns 404 for a missing group", %{conn: conn} do
    conn = get(conn, "/api/v1/groups/group-404")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "reflects payments, moves, and cancellation" do
    submit([
      open_group_op(%{"rate_plan" => "advance_purchase"}),
      payment_op(%{"amount_cents" => 40_000}),
      reschedule_op(%{"new_arrival_on" => "2027-01-05"})
    ])

    assert %{
             "revision" => 3,
             "status" => "active",
             "arrival_on" => "2027-01-05",
             "departure_on" => "2027-01-08",
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 97_500,
             "deposit_paid_cents" => 40_000,
             "outstanding_deposit_cents" => 57_500
           } = get_group("group-81")

    submit_one(cancel_op())

    # Group totals describe active rooms only, and a cancelled group has none.
    assert %{
             "revision" => 4,
             "status" => "cancelled",
             "lodging_total_cents" => 0,
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0,
             "rooms" => [
               %{"status" => "cancelled", "cash_paid_cents" => 0},
               %{"status" => "cancelled", "cash_paid_cents" => 0}
             ]
           } = get_group("group-81")
  end
end
