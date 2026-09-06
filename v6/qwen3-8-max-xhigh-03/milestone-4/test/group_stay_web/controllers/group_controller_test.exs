defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo

  defp open_group(conn, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-open",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "group-81",
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        },
        overrides
      )

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: [operation]}))
    |> json_response(200)
  end

  test "returns the group with its totals and rooms in their original order", %{conn: conn} do
    open_group(conn)

    data =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "revision" => 1,
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "rooms" => [
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }
  end

  test "returns identifiers unchanged", %{conn: conn} do
    open_group(conn, %{"group_id" => "Group 81/AMS", "guest_id" => "G-22", "property_id" => "P-9"})

    data =
      conn
      |> get("/api/v1/groups/Group%2081%2FAMS")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["group_id"] == "Group 81/AMS"
    assert data["guest_id"] == "G-22"
    assert data["property_id"] == "P-9"
  end

  test "returns 404 for a missing group", %{conn: conn} do
    response = get(conn, "/api/v1/groups/group-missing")

    assert json_response(response, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  describe "groups created before this release" do
    defp insert_legacy_group(now) do
      Repo.insert!(%GroupStay.Groups.Group{
        group_id: "group-old",
        guest_id: "guest-old",
        property_id: "ams-canal",
        booked_on: ~D[2026-06-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        lodging_total_cents: 30_000,
        deposit_due_cents: 6_000,
        deposit_paid_cents: 4_000,
        inserted_at: now,
        updated_at: now
      })

      # Rooms inserted by the earlier release: no room-level amounts yet.
      Repo.insert!(%GroupStay.Groups.Room{
        group_id: "group-old",
        room_id: "room-old",
        nightly_rate_cents: 10_000,
        position: 0,
        inserted_at: now,
        updated_at: now
      })
    end

    test "remain readable and receive the policy their booking date implies", %{conn: conn} do
      insert_legacy_group(DateTime.utc_now() |> DateTime.truncate(:second))

      data =
        conn
        |> get("/api/v1/groups/group-old")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
      assert data["deposit_paid_cents"] == 4_000
      assert data["cash_paid_cents"] == 4_000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 2_000

      # Legacy funding is carried forward as one unattributed senior block
      # without changing any balance.
      assert data["rooms"] == [
               %{
                 "room_id" => "room-old",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 4_000,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "still settle under their original policy", %{conn: conn} do
      insert_legacy_group(DateTime.utc_now() |> DateTime.truncate(:second))

      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/partner-batches",
        Jason.encode!(%{
          operations: [
            %{
              "operation_id" => "op-cancel-old",
              "type" => "cancel_group",
              "occurred_on" => "2026-11-26",
              "group_id" => "group-old"
            }
          ]
        })
      )
      |> json_response(200)

      data =
        conn
        |> get("/api/v1/groups/group-old")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["status"] == "cancelled"

      ledger =
        conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

      assert ledger["cash_refunded_cents"] == 4_000
    end
  end
end
