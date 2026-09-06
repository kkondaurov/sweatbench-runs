defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  alias GroupStay.{CreditApplication, CreditLot, Group, Payment, Repo}

  describe "room-level accounting on group reads" do
    test "exposes per-room status, deposit due, and funding", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert Enum.map(data["rooms"], & &1["room_id"]) == ~w(room-a room-b)

      assert Enum.map(data["rooms"], & &1["status"]) == ~w(active active)
      assert Enum.map(data["rooms"], & &1["deposit_due_cents"]) == [9_000, 10_500]
      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [5_000, 0]
      assert Enum.map(data["rooms"], & &1["credit_paid_cents"]) == [0, 0]

      assert %{
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "cash_paid_cents" => 5_000,
               "credit_paid_cents" => 0,
               "deposit_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500
             } = data
    end

    test "cash and credit fill one room before moving to the next", %{conn: conn} do
      guest = "guest-fill"

      {conn, _} =
        source_credit(conn, %{
          "group_id" => "group-src-fill",
          "operation_id" => "src-fill",
          "guest_id" => guest,
          "cash" => 10_000
        })

      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-fill",
            "group_id" => "group-fill",
            "guest_id" => guest
          })
        ])

      [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-fill",
          "group_id" => "group-fill",
          "amount_cents" => 8_000
        })
      )

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-fill",
          "group_id" => "group-fill",
          "occurred_on" => "2026-11-27",
          "amount_cents" => 5_000
        })
      )

      data = json_response(get(conn, groups_path("group-fill")), 200)["data"]

      # room-a needs 9_000: 8_000 cash + 1_000 credit; room-b then
      # receives the remaining 4_000 credit.
      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [8_000, 0]
      assert Enum.map(data["rooms"], & &1["credit_paid_cents"]) == [1_000, 4_000]
      assert data["deposit_paid_cents"] == 13_000
      assert data["outstanding_deposit_cents"] == 6_500
    end
  end

  describe "legacy funding bring-forward" do
    test "allocates the senior cash block before durable funding", %{conn: conn} do
      open_group!(conn)
      group = Repo.get_by!(Group, group_id: "group-81")

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "payment",
        operation_id: nil,
        amount_cents: 6_000
      })

      # Reading the group creates the allocations without changing the
      # aggregate cash balance.
      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [6_000, 0]
      assert data["outstanding_deposit_cents"] == 13_500

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 6_000

      # A durable payment allocates after the senior block, in commit order.
      json_post(conn, payment(%{"amount_cents" => 7_000}))

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [9_000, 4_000]
      assert data["deposit_paid_cents"] == 13_000
      assert data["outstanding_deposit_cents"] == 6_500

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 13_000
    end

    test "allocates legacy credit in consumption order after legacy cash", %{conn: conn} do
      open_group!(conn)
      group = Repo.get_by!(Group, group_id: "group-81")

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "payment",
        operation_id: nil,
        amount_cents: 6_000
      })

      lot =
        Repo.insert!(%CreditLot{
          guest_id: "guest-22",
          source_operation_id: "old-cancel",
          expires_on: ~D[2027-12-31],
          remaining_cents: 500
        })

      Repo.insert!(%CreditApplication{
        lot_id: lot.id,
        group_id: group.id,
        amount_cents: 4_000,
        status: "applied",
        operation_id: nil
      })

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      # Legacy aggregate cash first (6_000 on room-a), then legacy credit in
      # consumption order (3_000 finishing room-a, 1_000 starting room-b).
      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [6_000, 0]
      assert Enum.map(data["rooms"], & &1["credit_paid_cents"]) == [3_000, 1_000]
      assert data["deposit_paid_cents"] == 10_000
      assert data["outstanding_deposit_cents"] == 9_500

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 6_000
      assert ledger["credit_liability_cents"] == 4_500
    end

    test "legacy funding is brought forward at most once", %{conn: conn} do
      open_group!(conn)
      group = Repo.get_by!(Group, group_id: "group-81")

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "payment",
        operation_id: nil,
        amount_cents: 6_000
      })

      for _ <- 1..3 do
        data = json_response(get(conn, groups_path("group-81")), 200)["data"]
        assert data["cash_paid_cents"] == 6_000
      end

      json_post(conn, payment(%{"amount_cents" => 3_000}))

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [9_000, 0]
    end

    test "a cancelled group from before this release settles through forwarding", %{conn: conn} do
      group =
        Repo.insert!(%Group{
          group_id: "group-old-cancelled",
          guest_id: "guest-22",
          property_id: "p",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          status: "cancelled",
          revision: 3
        })

      Repo.insert!(%GroupStay.Room{
        group_id: group.id,
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        position: 0,
        status: "active"
      })

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "payment",
        operation_id: nil,
        amount_cents: 9_000
      })

      Repo.insert!(%Payment{
        group_id: group.id,
        kind: "refund",
        operation_id: nil,
        amount_cents: 9_000
      })

      data = json_response(get(conn, groups_path("group-old-cancelled")), 200)["data"]

      assert data["status"] == "cancelled"
      assert data["lodging_total_cents"] == 0
      assert data["deposit_due_cents"] == 0
      assert data["deposit_paid_cents"] == 0
      assert Enum.map(data["rooms"], & &1["status"]) == ["cancelled"]

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 9_000
    end
  end

  # Opens a source group for the guest, pays it, and cancels it with hotel
  # credit so the guest owns a usable credit lot.
  defp source_credit(conn, overrides) do
    group_id = Map.get(overrides, "group_id", "group-src")
    guest_id = Map.get(overrides, "guest_id", "guest-src")
    operation_id = Map.get(overrides, "operation_id", "group-src")
    cash = Map.get(overrides, "cash", 10_000)

    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-#{operation_id}",
          "group_id" => group_id,
          "guest_id" => guest_id
        }),
        payment(%{
          "operation_id" => "pay-#{operation_id}",
          "group_id" => group_id,
          "amount_cents" => cash
        }),
        cancel(%{
          "operation_id" => "cancel-#{operation_id}",
          "group_id" => group_id,
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      ])

    results = json_response(conn, 200)["results"]

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             results

    {conn, Enum.at(results, 2)}
  end
end
