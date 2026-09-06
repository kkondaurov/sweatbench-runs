defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "a guest who never received credit holds none" do
    assert read_credit("guest-404") == %{
             "guest_id" => "guest-404",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "returns the lots credit is left in" do
    issue_credit(group_id: "group-1", cash_cents: 5_000, operation_id: "cancel-17")

    assert read_credit("guest-22") == %{
             "guest_id" => "guest-22",
             "available_cents" => 5_500,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-11-26"
               }
             ]
           }
  end

  test "orders lots by expiry, then by source operation id" do
    issue_credit(group_id: "group-1", cash_cents: 1_000, operation_id: "cancel-b")
    issue_credit(group_id: "group-2", cash_cents: 2_000, operation_id: "cancel-a")

    issue_credit(
      group_id: "group-3",
      cash_cents: 3_000,
      operation_id: "cancel-c",
      cancelled_on: "2026-11-20"
    )

    assert Enum.map(read_credit("guest-22")["lots"], & &1["source_operation_id"]) ==
             ["cancel-c", "cancel-a", "cancel-b"]
  end

  test "each guest sees only their own credit" do
    issue_credit(group_id: "group-1", cash_cents: 1_000, operation_id: "cancel-1")

    issue_credit(
      group_id: "group-2",
      cash_cents: 2_000,
      operation_id: "cancel-2",
      guest_id: "guest-99"
    )

    assert read_credit("guest-22")["available_cents"] == 1_100
    assert read_credit("guest-99")["available_cents"] == 2_200
  end

  test "reports expiry as of the requested date" do
    issue_credit(group_id: "group-1", cash_cents: 1_000, operation_id: "cancel-1")

    assert read_credit("guest-22", %{"on" => "2027-11-26"})["available_cents"] == 1_100

    assert read_credit("guest-22", %{"on" => "2027-11-27"}) == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "omits exhausted lots" do
    issue_credit(group_id: "group-1", cash_cents: 1_000, operation_id: "cancel-1")

    submit([
      open_group(%{"group_id" => "group-2", "rooms" => [room("room-a", 15_000)]}),
      apply_hotel_credit(%{"group_id" => "group-2", "amount_cents" => 1_100})
    ])

    assert read_credit("guest-22") == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "returns partner identifiers unchanged" do
    issue_credit(
      group_id: "group-1",
      cash_cents: 1_000,
      operation_id: "Cancel~17",
      guest_id: "Guest.22_AMS"
    )

    credit = read_credit("Guest.22_AMS")
    assert credit["guest_id"] == "Guest.22_AMS"
    assert [%{"source_operation_id" => "Cancel~17"}] = credit["lots"]
  end

  test "rejects a date it cannot read" do
    assert {422, body} = get_json("/api/v1/guests/guest-22/credit", %{"on" => "2027-13-40"})
    assert body == %{"error" => %{"code" => "invalid_query"}}

    assert {422, _} = get_json("/api/v1/guests/guest-22/credit", %{"on" => ""})
  end
end
