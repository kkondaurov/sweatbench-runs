defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  test "returns the full group with rooms in their original order" do
    op =
      open_group_op(%{
        "rooms" => [
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
        ]
      })

    {_, 200} = api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => [op]})

    {body, status} = api_get(build_conn(), "/api/v1/groups/group-81")

    assert status == 200

    assert body["data"]["rooms"] == [
             %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
             %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
           ]
  end

  test "returns identifiers unchanged" do
    {_, 200} =
      api_post(build_conn(), "/api/v1/partner-batches", %{
        "operations" => [
          open_group_op(%{"group_id" => "Group A", "guest_id" => "g-1", "property_id" => "p-1"})
        ]
      })

    {body, 200} = api_get(build_conn(), "/api/v1/groups/Group%20A")

    assert body["data"]["group_id"] == "Group A"
    assert body["data"]["guest_id"] == "g-1"
    assert body["data"]["property_id"] == "p-1"
  end

  test "returns 404 for a missing group" do
    {body, status} = api_get(build_conn(), "/api/v1/groups/group-unknown")

    assert status == 404
    assert body == %{"error" => %{"code" => "group_not_found"}}
  end
end
