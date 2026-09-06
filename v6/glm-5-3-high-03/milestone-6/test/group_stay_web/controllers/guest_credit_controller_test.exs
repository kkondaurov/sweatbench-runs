defmodule GroupStayWeb.GuestCreditControllerTest do
  @moduledoc """
  Coverage of the guest credit read endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  defp issue_credit(operation_id, group_id, cash_cents, cancelled_on) do
    post_batch([
      open_group_operation("op-1-" <> operation_id, %{"group_id" => group_id}),
      pay_operation("op-2-" <> operation_id, group_id, cash_cents, %{
        "occurred_on" => "2026-10-04"
      }),
      cancel_operation(operation_id, group_id, %{
        "occurred_on" => cancelled_on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  test "a guest without credit has none available" do
    assert json_response(get_guest_credit("guest-none"), 200) == %{
             "data" => %{"guest_id" => "guest-none", "available_cents" => 0, "lots" => []}
           }
  end

  test "lists the lots of a guest with the documented shape" do
    issue_credit("cancel-17", "group-81", 5_000, "2026-11-26")

    assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }
           }
  end

  test "lots are ordered by expires_on, then by source_operation_id" do
    issue_credit("cancel-b", "group-a", 5_000, "2026-11-10")
    issue_credit("cancel-a", "group-b", 5_000, "2026-11-20")

    assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"]["lots"] ==
             Enum.map(
               [
                 {"cancel-b", "2027-11-11"},
                 {"cancel-a", "2027-11-21"}
               ],
               fn {source_operation_id, expires_on} ->
                 %{
                   "source_operation_id" => source_operation_id,
                   "remaining_cents" => 5_500,
                   "expires_on" => expires_on
                 }
               end
             )
  end

  test "expired and exhausted lots are omitted" do
    issue_credit("cancel-17", "group-81", 5_000, "2026-11-26")

    # available through 2027-11-26, expired on 2027-11-27
    assert json_response(get_guest_credit("guest-22", "2027-11-26"), 200)["data"][
             "available_cents"
           ] == 5_500

    assert json_response(get_guest_credit("guest-22", "2027-11-27"), 200)["data"] == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "without on the endpoint uses the current UTC date" do
    today = Date.utc_today()

    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 5_000),
      cancel_operation("op-3", "group-81", %{
        "occurred_on" => Date.to_iso8601(today),
        "refund_method" => "hotel_credit"
      })
    ])

    assert json_response(get_guest_credit("guest-22"), 200)["data"]["available_cents"] == 5_500
  end

  test "credit applied to an active group is not available" do
    issue_credit("cancel-17", "group-81", 5_000, "2026-11-26")

    post_batch([
      open_group_operation("op-4", %{"group_id" => "group-82"}),
      apply_credit_operation("op-5", "group-82", 2_000, %{"occurred_on" => "2026-11-27"})
    ])

    assert json_response(get_guest_credit("guest-22", "2026-12-01"), 200)["data"] == %{
             "guest_id" => "guest-22",
             "available_cents" => 3_500,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 3_500,
                 "expires_on" => "2027-11-27"
               }
             ]
           }
  end
end
