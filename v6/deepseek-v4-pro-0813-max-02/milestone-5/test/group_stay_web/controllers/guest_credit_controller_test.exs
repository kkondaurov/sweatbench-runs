defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp issue_credit(cancel_operation_id, occurred_on, opts \\ []) do
    group_id = Keyword.get(opts, :group_id, "group-#{cancel_operation_id}")

    open =
      open_group_op(%{
        "operation_id" => "#{cancel_operation_id}-open",
        "group_id" => group_id,
        "occurred_on" => "2026-01-05",
        "arrival_on" => "2026-06-01",
        "departure_on" => "2026-06-04",
        "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
      })

    payment =
      cash_payment_op(%{
        "operation_id" => "#{cancel_operation_id}-pay",
        "group_id" => group_id,
        "amount_cents" => 5_000
      })

    cancellation =
      cancel_op(%{
        "operation_id" => cancel_operation_id,
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })

    {_, 200} = post_ops([open, payment, cancellation])
  end

  test "returns lots ordered by expiry and then source operation id" do
    issue_credit("op-9102", "2026-04-05")
    issue_credit("op-9101", "2026-04-01")

    {body, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")

    assert body == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-9101",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-04-01"
                 },
                 %{
                   "source_operation_id" => "op-9102",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-04-05"
                 }
               ]
             }
           }
  end

  test "omits exhausted lots" do
    issue_credit("op-9101", "2026-04-01")

    {_, 200} = post_ops([open_group_op()])

    {_, 200} =
      post_ops([apply_hotel_credit_op(%{"occurred_on" => "2026-04-02", "amount_cents" => 5_500})])

    {body, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")

    assert body == %{"data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}}
  end

  test "omits lots that expired as of the on date and defaults to the current date" do
    issue_credit("op-9101", "2026-04-01")

    {body, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-04-01")
    assert body["data"]["available_cents"] == 5_500
    assert length(body["data"]["lots"]) == 1

    {body, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-04-02")
    assert body["data"]["available_cents"] == 0
    assert body["data"]["lots"] == []

    # No `on` uses the current UTC date, which precedes the 2027 expiry.
    {body, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
    assert body["data"]["available_cents"] == 5_500
  end

  test "returns empty credit for an unknown guest" do
    {body, 200} = api_get(build_conn(), "/api/v1/guests/guest-unknown/credit")

    assert body == %{
             "data" => %{"guest_id" => "guest-unknown", "available_cents" => 0, "lots" => []}
           }
  end
end
